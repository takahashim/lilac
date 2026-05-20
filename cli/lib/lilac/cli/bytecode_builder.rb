# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

require_relative 'build_error'
require_relative 'wasm_mrbc_driver'

module Lilac
  module CLI
    # Compiles aggregated Ruby source to mruby bytecode, then writes it
    # under the build output with a content-hash filename so browsers
    # cache-invalidate automatically when the bytes change.
    #
    # Used by `Builder` when `target == :compiled`. Owns the compile
    # subprocess (or wasm driver) lifecycle and error translation;
    # `Builder` keeps the HTML / vendor concerns.
    #
    # Backend dispatch — first hit wins:
    #
    #   1. explicit `mrbc_path:` (from `Lilac::CLI.configure { c.mrbc_path = ... }`
    #      or `--mrbc-path` CLI flag)                                  → :binary
    #   2. ENV["MRBC"]                                                  → :binary
    #   3. ENV["MRUBY_WASM_RUNTIME_PATH"]/mruby/build/host/bin/mrbc     → :binary
    #   4. `lilac-wasm-bin` gem ships `mrbc-host.wasm` AND wasmtime-rb
    #      loadable AND module instantiates with required exports       → :wasm
    #   5. `mrbc` on $PATH                                              → :binary
    #
    # The wasm-driven backend is the "default for end users" path — a
    # scaffolded `lilac new` Gemfile pulls in `lilac-wasm-bin` and
    # `wasmtime`, so `gem install lilac-cli && bundle install` is enough
    # to make `lilac build --target compiled` work without any external
    # binary. Explicit `mrbc_path` / ENV vars override (priority 1-3) so
    # devs who built mruby themselves get the native path.
    #
    # If nothing resolves, raises BuildError pointing at the most likely
    # fix paths.
    class BytecodeBuilder
      class Error < BuildError; end

      # 8 hex chars (32 bits) — enough collision resistance for cache
      # busting, short enough to keep filenames readable.
      HASH_LENGTH = 8

      def initialize(output_dir:, mrbc_path: nil, basename: 'app',
                     disable_gem_discovery: false)
        @configured_mrbc_path = mrbc_path
        @output_dir = output_dir
        @basename = basename
        # Mirrors `CompiledRuntimeResolver`'s kwarg — lets the bytecode
        # builder's tests sandbox out the gem's `mrbc-host.wasm` when
        # they want to assert specific discovery fallbacks. Production
        # callers leave it false and the gem's wasm is picked up by
        # default (priority #4).
        @disable_gem_discovery = disable_gem_discovery
      end

      # Compile a Ruby source string into a `.mrb` file under
      # `output_dir`. Returns the basename of the produced file (e.g.
      # `"app.a3f29b21.mrb"`) so the caller can wire it into a fetch URL.
      def build(ruby_source, source_label: '(aggregated)')
        FileUtils.mkdir_p(@output_dir)
        backend = resolve_backend!

        bytecode = case backend.first
                   when :binary then compile_via_binary(backend.last, ruby_source, source_label)
                   when :wasm   then compile_via_wasm(backend.last, ruby_source, source_label)
                   end

        filename = "#{@basename}.#{content_hash(bytecode)}.mrb"
        dest = File.join(@output_dir, filename)
        File.binwrite(dest, bytecode)
        filename
      end

      # Diagnostic accessor: returns `[:binary, "/path"]` or
      # `[:wasm, "/path/to/wasm"]` describing which backend `build` would
      # select, or nil when nothing resolves. Doesn't raise — `lilac
      # doctor` uses it to render the OK / WARN line; `build` calls
      # `resolve_backend!` instead.
      def resolve_backend
        if (binary = resolve_mrbc_binary)
          return [:binary, binary]
        end
        if (wasm = discoverable_mrbc_host_wasm) && WasmMrbcDriver.available?(wasm_path: wasm)
          return [:wasm, wasm]
        end
        if (path_binary = path_lookup('mrbc'))
          return [:binary, path_binary]
        end

        nil
      end

      # Resolved mrbc binary path for `lilac doctor` and back-compat.
      # Nil when no binary is discoverable (gem-provided wasm doesn't
      # count). Renamed-but-kept-as-alias for callers that pre-date the
      # backend dispatch (e.g. existing tests).
      def resolve_mrbc
        resolve_mrbc_binary || path_lookup('mrbc')
      end

      private

      # Discovery routes 1-3 from the docstring above — explicit
      # arg / ENV / monorepo convention. The PATH fallback (#5) lives
      # in `resolve_backend` so it's only consulted after the wasm
      # backend has been tried.
      def resolve_mrbc_binary
        @configured_mrbc_path && File.executable?(@configured_mrbc_path) and return @configured_mrbc_path
        if (env = ENV['MRBC']) && File.executable?(env)
          return env
        end

        if (mwr = ENV['MRUBY_WASM_RUNTIME_PATH'])
          candidate = File.join(mwr, 'mruby', 'build', 'host', 'bin', 'mrbc')
          return candidate if File.executable?(candidate)
        end
        nil
      end

      def discoverable_mrbc_host_wasm
        return nil if @disable_gem_discovery

        require 'lilac/wasm/bin'
        ::Lilac::Wasm::Bin.mrbc_host_wasm
      rescue LoadError
        nil
      end

      def resolve_backend!
        resolve_backend || raise(Error, backend_not_found_message)
      end

      def compile_via_binary(mrbc, ruby_source, source_label)
        Dir.mktmpdir('lilac-mrbc-') do |dir|
          tmp_rb  = File.join(dir, 'input.rb')
          tmp_mrb = File.join(dir, 'input.mrb')
          File.write(tmp_rb, ruby_source)

          stdout, stderr, status = Open3.capture3(mrbc, '-o', tmp_mrb, tmp_rb)
          raise Error, binary_error_message(source_label, stdout, stderr, status) unless status.success?

          File.binread(tmp_mrb)
        end
      end

      def compile_via_wasm(wasm_path, ruby_source, source_label)
        # Reuse the driver across `build` calls within a single
        # invocation — engine + module + instance setup is the slow part
        # (~200-500ms cold) and is amortized over every component.
        @wasm_driver ||= WasmMrbcDriver.new(wasm_path: wasm_path)
        @wasm_driver.compile(ruby_source)
      rescue WasmMrbcDriver::CompileError => e
        raise Error, "mrbc-host.wasm failed compiling #{source_label}:\n#{e.message}"
      rescue WasmMrbcDriver::WasmtimeMissingError, WasmMrbcDriver::WasmExportMissingError => e
        # Shouldn't reach here under normal flow — `resolve_backend!`
        # only returns `:wasm` after `available?` succeeded — but if the
        # wasm path goes stale mid-build (e.g. file removed), surface
        # the typed error rather than crashing.
        raise Error, "wasm mrbc backend unavailable: #{e.message}"
      end

      def content_hash(bytes)
        Digest::SHA256.hexdigest(bytes)[0, HASH_LENGTH]
      end

      # Walk $PATH for `name`. Falls back to nil when not found —
      # callers translate to a user-facing error with
      # `backend_not_found_message`.
      def path_lookup(name)
        (ENV['PATH'] || '').split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.executable?(candidate) && !File.directory?(candidate)
        end
        nil
      end

      def backend_not_found_message
        <<~MSG.strip
          No mrbc backend found. Tried (in priority order):
            1. configured `c.mrbc_path` / `--mrbc-path`
            2. ENV["MRBC"]
            3. ENV["MRUBY_WASM_RUNTIME_PATH"]/mruby/build/host/bin/mrbc
            4. lilac-wasm-bin gem's mrbc-host.wasm (wasmtime-rb driven)
            5. `mrbc` on $PATH

          To fix, either:
            • Add `gem "lilac-wasm-bin"` and `gem "wasmtime"` to your Gemfile
              (recommended — the scaffolded Gemfile from `lilac new` already does this)
            • Set ENV["MRBC"]=/abs/path/to/mrbc
            • Set ENV["MRUBY_WASM_RUNTIME_PATH"] to a built mruby-wasm-runtime checkout
            • Add `c.mrbc_path = "/abs/path"` to lilac.config.rb
            • Put `mrbc` on your $PATH (e.g. build mruby locally)
        MSG
      end

      def binary_error_message(source_label, _stdout, stderr, status)
        "mrbc failed (exit=#{status.exitstatus}) compiling #{source_label}:\n#{stderr.strip}"
      end
    end
  end
end
