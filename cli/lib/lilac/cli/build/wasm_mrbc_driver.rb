# frozen_string_literal: true

module Lilac
  module CLI
    # Drives `mrbc-host.wasm` from the host Ruby via `wasmtime-rb` to
    # produce mruby bytecode in place of an external `mrbc` binary.
    #
    # Wire-level ABI (defined in `runtime/mruby-host-compile/src/host_compile.c`):
    #
    #   compile_source(src_ptr, src_len,
    #                  out_ptr_outp, out_len_outp,
    #                  err_ptr_outp, err_len_outp) -> i32 status
    #   mrbc_alloc(len) -> i32 ptr   (host writes/reads through this buffer)
    #   mrbc_free(ptr)               (host frees both input and output)
    #
    # Status codes:
    #   0  ok           — irep bytes in out_ptr / out_len
    #   1  compile fail — utf-8 message in err_ptr / err_len
    #   2  no compiler  — wasm was built without mruby-compiler
    #
    # Lifecycle: the engine + module + instance are created once on the
    # first `compile` call and reused across subsequent calls within a
    # single `BytecodeBuilder` invocation. mruby's `mrb_state` itself is
    # opened/closed *inside* the wasm per call (see `compile_source` in
    # host_compile.c) — this matches `mrbc` binary's process-per-invocation
    # semantics and keeps symbol-table growth from leaking across builds.
    class WasmMrbcDriver
      class Error < StandardError; end
      class WasmtimeMissingError < Error; end
      class WasmExportMissingError < Error; end
      class CompileError < Error; end

      REQUIRED_EXPORTS = %w[compile_source mrbc_alloc mrbc_free memory].freeze

      # Test whether a usable backend can be constructed from `wasm_path`.
      # Returns true only when wasmtime-rb is loadable AND the module
      # parses + instantiates AND all required exports are present.
      #
      # Used by `BytecodeBuilder#resolve_backend!` to decide between the
      # wasm-driven and binary mrbc paths; also surfaced via `lilac doctor`
      # so users can see exactly why the wasm path was/wasn't picked.
      #
      # wasmtime-rb's `Module` doesn't expose `exports` directly, so we
      # actually instantiate to enumerate the exports. The cost (~200-500ms
      # cold) is paid once per `lilac build`, which is acceptable for a
      # build-time tool.
      def self.available?(wasm_path:)
        return false unless wasm_path && File.file?(wasm_path)

        begin
          require 'wasmtime'
        rescue LoadError
          return false
        end

        begin
          engine = Wasmtime::Engine.new(wasm_exceptions: true)
          mod = Wasmtime::Module.from_file(engine, wasm_path)
          linker = Wasmtime::Linker.new(engine)
          Wasmtime::WASI::P1.add_to_linker_sync(linker)
          store = Wasmtime::Store.new(engine, wasi_p1_config: Wasmtime::WasiConfig.new)
          instance = linker.instantiate(store, mod)
          REQUIRED_EXPORTS.all? { |name| !instance.export(name).nil? }
        rescue Wasmtime::Error, ArgumentError
          false
        end
      end

      def initialize(wasm_path:)
        @wasm_path = wasm_path
      end

      attr_reader :wasm_path

      # Compile a Ruby source string and return the raw mruby bytecode
      # (binary string, starts with "RITE" magic). Raises CompileError on
      # syntax/semantic errors (carrying the parser's error buffer text)
      # or WasmExportMissingError / WasmtimeMissingError on environment
      # problems.
      def compile(ruby_source)
        ensure_instance!

        # mrbc_alloc returns 0 on size <= 0 or malloc failure. We allocate
        # six buffers per call:
        #   src_buf    — caller-written source bytes
        #   out_p/out_l — out-params written by compile_source on success
        #   err_p/err_l — out-params written by compile_source on failure
        # The three out-param pairs are 4-byte i32 each.
        src_bytes = ruby_source.b
        src_buf = @alloc.call(src_bytes.bytesize)
        raise CompileError, 'mrbc_alloc returned 0 for src buffer' if src_buf.zero?

        out_p = @alloc.call(4)
        out_l = @alloc.call(4)
        err_p = @alloc.call(4)
        err_l = @alloc.call(4)
        if [out_p, out_l, err_p, err_l].any?(&:zero?)
          [src_buf, out_p, out_l, err_p, err_l].each { |p| @free.call(p) unless p.zero? }
          raise CompileError, 'mrbc_alloc returned 0 for out-param buffers'
        end

        @memory.write(src_buf, src_bytes)

        status = @compile.call(src_buf, src_bytes.bytesize, out_p, out_l, err_p, err_l)

        irep_ptr = read_i32(out_p)
        irep_len = read_i32(out_l)
        err_ptr  = read_i32(err_p)
        err_len  = read_i32(err_l)

        case status
        when 0
          bytecode = @memory.read(irep_ptr, irep_len)
          @free.call(irep_ptr)
          bytecode
        when 1
          message = err_len.positive? ? @memory.read(err_ptr, err_len).force_encoding('UTF-8') : '(no message)'
          @free.call(err_ptr) unless err_ptr.zero?
          raise CompileError, message
        when 2
          raise WasmExportMissingError,
                'mrbc-host.wasm was built without mruby-compiler — rebuild with build_config/mrbc-host.rb'
        else
          raise CompileError, "compile_source returned unexpected status=#{status}"
        end
      ensure
        # Free the input buffer and the four out-param scratch buffers.
        # irep_ptr / err_ptr were freed inside the case branches because
        # they're the wasm's own malloc'd outputs (separate from the
        # 4-byte holders the host allocated for the pointer values).
        [src_buf, out_p, out_l, err_p, err_l].compact.each do |p|
          @free.call(p) unless p.zero?
        end
      end

      private

      # Lazy initialization: avoid paying the ~200-500ms wasmtime cold
      # compile cost if the caller only uses `available?` for discovery
      # and never actually compiles anything.
      def ensure_instance!
        return if @instance

        begin
          require 'wasmtime'
        rescue LoadError => e
          raise WasmtimeMissingError, "wasmtime-rb not available: #{e.message}"
        end

        @engine = Wasmtime::Engine.new(wasm_exceptions: true)
        @module = Wasmtime::Module.from_file(@engine, @wasm_path)

        # WASI is wired even though host_compile.c doesn't deliberately
        # call into it — mruby-wasm-runtime / wasi-libc reference fd_write,
        # fd_fdstat_get, etc. at link time even when those code paths are
        # unreachable, so wasmtime requires the imports to be satisfied.
        linker = Wasmtime::Linker.new(@engine)
        Wasmtime::WASI::P1.add_to_linker_sync(linker)
        store = Wasmtime::Store.new(@engine, wasi_p1_config: Wasmtime::WasiConfig.new)
        @instance = linker.instantiate(store, @module)

        if (init = @instance.export('_initialize')&.to_func)
          init.call
        end

        @memory  = export_or_raise('memory').to_memory
        @alloc   = export_or_raise('mrbc_alloc').to_func
        @free    = export_or_raise('mrbc_free').to_func
        @compile = export_or_raise('compile_source').to_func
      end

      def export_or_raise(name)
        @instance.export(name) ||
          raise(WasmExportMissingError,
                "#{File.basename(@wasm_path)} is missing required export `#{name}`")
      end

      def read_i32(ptr)
        @memory.read(ptr, 4).unpack1('l<')
      end
    end
  end
end
