# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

require_relative "build_error"

module Lilac
  module CLI
    # Compiles aggregated Ruby source to mruby bytecode via `mrbc`, then
    # writes it under the build output with a content-hash filename so
    # browsers cache-invalidate automatically when the bytes change.
    #
    # Used by `Builder` when `target == :compiled`. Owns the mrbc
    # subprocess lifecycle and error translation; `Builder` keeps the
    # HTML / vendor concerns.
    #
    # mrbc path resolution (first hit wins):
    #
    #   1. explicit `mrbc_path:` (from `Lilac::CLI.configure { c.mrbc_path = ... }`
    #      or `--mrbc-path` CLI flag)
    #   2. ENV["MRBC"]
    #   3. ENV["MRUBY_WASM_RUNTIME_PATH"]/mruby/build/host/bin/mrbc
    #      (the conventional location when the user followed the
    #      mruby-wasm-runtime setup)
    #   4. `mrbc` on $PATH
    #
    # If nothing is found, raises BuildError pointing at the most likely
    # fix paths so the user can recover without spelunking.
    class BytecodeBuilder
      class Error < BuildError; end

      # 8 hex chars (32 bits) — enough collision resistance for cache
      # busting, short enough to keep filenames readable.
      HASH_LENGTH = 8

      def initialize(mrbc_path: nil, output_dir:, basename: "app")
        @configured_mrbc_path = mrbc_path
        @output_dir = output_dir
        @basename = basename
      end

      # Compile a Ruby source string into a `.mrb` file under
      # `output_dir`. Returns the basename of the produced file (e.g.
      # `"app.a3f29b21.mrb"`) so the caller can wire it into a fetch URL.
      def build(ruby_source, source_label: "(aggregated)")
        FileUtils.mkdir_p(@output_dir)
        mrbc = resolve_mrbc!

        Dir.mktmpdir("lilac-mrbc-") do |dir|
          tmp_rb  = File.join(dir, "input.rb")
          tmp_mrb = File.join(dir, "input.mrb")
          File.write(tmp_rb, ruby_source)

          stdout, stderr, status = Open3.capture3(mrbc, "-o", tmp_mrb, tmp_rb)
          unless status.success?
            raise Error, build_error_message(source_label, stdout, stderr, status)
          end

          bytecode = File.binread(tmp_mrb)
          filename = "#{@basename}.#{content_hash(bytecode)}.mrb"
          dest = File.join(@output_dir, filename)
          File.binwrite(dest, bytecode)
          filename
        end
      end

      # Resolved mrbc path for diagnostics (`lilac doctor` etc.); nil
      # when discovery fails. Does not raise — call `resolve_mrbc!` from
      # the build path where failing is the desired behaviour.
      def resolve_mrbc
        @configured_mrbc_path && File.executable?(@configured_mrbc_path) and return @configured_mrbc_path
        if (env = ENV["MRBC"]) && File.executable?(env)
          return env
        end
        if (mwr = ENV["MRUBY_WASM_RUNTIME_PATH"])
          candidate = File.join(mwr, "mruby", "build", "host", "bin", "mrbc")
          return candidate if File.executable?(candidate)
        end
        path_lookup("mrbc")
      end

      private

      def resolve_mrbc!
        resolve_mrbc || raise(Error, mrbc_not_found_message)
      end

      def content_hash(bytes)
        Digest::SHA256.hexdigest(bytes)[0, HASH_LENGTH]
      end

      # Walk $PATH for `name`. Falls back to nil when not found —
      # callers translate to a user-facing error with `mrbc_not_found_message`.
      def path_lookup(name)
        (ENV["PATH"] || "").split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.executable?(candidate) && !File.directory?(candidate)
        end
        nil
      end

      def mrbc_not_found_message
        <<~MSG.strip
          mrbc not found. Tried: configured `c.mrbc_path`, ENV["MRBC"],
          ENV["MRUBY_WASM_RUNTIME_PATH"]/mruby/build/host/bin/mrbc, $PATH.

          To fix, either:
            • Set ENV["MRBC"]=/abs/path/to/mrbc
            • Set ENV["MRUBY_WASM_RUNTIME_PATH"] to a built mruby-wasm-runtime checkout
            • Add `c.mrbc_path = "/abs/path"` to lilac.config.rb
            • Put `mrbc` on your $PATH (e.g. `gem install mruby` or build mruby locally)
        MSG
      end

      def build_error_message(source_label, _stdout, stderr, status)
        "mrbc failed (exit=#{status.exitstatus}) compiling #{source_label}:\n#{stderr.strip}"
      end
    end
  end
end
