# mruby cross-build for the "mrbc-host" variant — a minimal
# compiler-only wasm reactor that exposes mruby's parser + codegen
# + bytecode dumper via the `mruby-host-compile` mrbgem.
#
# This wasm is loaded by `lilac-cli`'s `WasmMrbcDriver` through
# `wasmtime-rb` (shipped as a runtime dep of `lilac-wasm-bin`).
# It replaces the standalone `mrbc` binary for the `lilac build
# --target compiled` flow so a `gem install lilac-cli && bundle
# install` workflow completes without any external mrbc binary.
#
# Why a separate variant (not reusing lilac-full.wasm):
#   Both this and `lilac-full.wasm` now use the **new** EH proposal
#   (`try_table` via `-mllvm -wasm-use-legacy-eh=false`), so either
#   could run under wasmtime-rb v45. The split is purely about **size**:
#   mrbc-host is compiler-only (parser + codegen + dumper) and omits all
#   the Lilac framework gems, keeping the wasm-driven `mrbc` backend
#   small. `lilac-full` carries the whole runtime.
#
# Why not just drop sjlj entirely:
#   mruby's `mrb_protect` / `mrb_raise` paths call `setjmp` / `longjmp`,
#   and wasi-sysroot's `libsetjmp.a` requires the `__wasm_setjmp` /
#   `__wasm_longjmp` symbols produced by the LLVM SjLj transformation.
#   Without `-wasm-enable-sjlj` you get link errors on those symbols.
#
# Output (linked by the Makefile, not this build_config):
#   build/mrbc-host.wasm  (dev)   — for local iteration
#   build/mrbc-host.release.wasm  — shipped in lilac-wasm-bin/data/

LOCAL_WASM_RUNTIME = ENV["MRUBY_WASM_RUNTIME_PATH"]
unless LOCAL_WASM_RUNTIME && File.directory?(LOCAL_WASM_RUNTIME)
  abort <<~MSG
    Lilac's build needs a local clone of mruby-wasm-runtime.

    Set MRUBY_WASM_RUNTIME_PATH to point at it:

      export MRUBY_WASM_RUNTIME_PATH=$(cd .. && pwd)/mruby-wasm-runtime
  MSG
end

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = release ? "mrbc-host-release" : "mrbc-host"

runtime_dir = File.expand_path("../runtime", __dir__)

MRuby::CrossBuild.new(build_name) do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  # `-wasm-use-legacy-eh=false` selects the new EH proposal
  # (`try_table` opcode) — accepted by wasmtime-rb 44.x out of the box.
  # The legacy form (`try` / `catch`) requires a feature flag that
  # current wasmtime-rb doesn't expose.
  sjlj_flags = [
    "-mllvm", "-wasm-enable-sjlj",
    "-mllvm", "-wasm-use-legacy-eh=false",
  ]
  size_flags = release ? ["-Oz"] : []
  conf.cc.flags.concat(common_flags + size_flags + sjlj_flags)
  conf.cxx.flags.concat(common_flags + size_flags + sjlj_flags)
  conf.linker.flags.concat(common_flags)

  conf.linker.flags << "-Wl,--allow-undefined"
  conf.linker.flags << "-Wl,--strip-debug" if release
  conf.linker.flags << "-mexec-model=reactor"

  conf.linker.libraries << "setjmp"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # Compiler-only stdlib — just what mruby-compiler + host_compile.c
  # need at codegen time. No I/O, no fiber, no array/hash extensions:
  # we're parsing source bytes and emitting irep, nothing else.
  conf.gem core: "mruby-sprintf"   # used by parser's error formatting
  conf.gem core: "mruby-metaprog"  # required by mruby-compiler internals

  # mruby-host-compile pulls in mruby-compiler transitively.
  conf.gem "#{runtime_dir}/mruby-host-compile"

  conf.bins = []
end
