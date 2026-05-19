# mruby cross-build for the "compiled" Lilac variant.
#
# Goals: smallest production JS-host wasm. Companion to `lilac-cli`
# (Ruby gem) — apps shipped against this build MUST be pre-compiled
# with `lilac build` / `mrbc` and loaded via `vm.loadIrep(bytes)`.
# `vm.eval(source)` raises NotImplementedError (the JS bridge surfaces
# it) because no mruby-compiler is bundled.
#
# What's in:
#  - Lilac core + Lilac form gem (decisions §2: form is core)
#  - mruby-regexp-compat (Regexp class for user code & form validators)
#  - tightly-selected mruby core gems Lilac actually touches
#
# What's out:
#  - mruby-compiler / mruby-eval (= no runtime parser)
#  - Lilac directives scanner (CLI codegen emits explicit
#    `Lilac::Bindings::*` modules; runtime needs no scanner)
#  - Lilac async (Fetchy / Resource) / router
#  - WASI io (mruby-io / mruby-wasi-*)
#
# Surfaces as `@takahashim/lilac-compiled` on npm (see npm/lilac-compiled/).
#
# Environment knobs:
#   MRUBY_WASM_RELEASE=1     enable -Os + --strip-debug
#   MRUBY_WASM_RUNTIME_PATH  local mruby-wasm-runtime clone (required)

LOCAL_WASM_RUNTIME = ENV["MRUBY_WASM_RUNTIME_PATH"]
unless LOCAL_WASM_RUNTIME && File.directory?(LOCAL_WASM_RUNTIME)
  abort "Set MRUBY_WASM_RUNTIME_PATH to a local mruby-wasm-runtime clone " \
        "(see .envrc or lilac-full.rb)"
end

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = "lilac-compiled"
build_name += "-release" if release
mwr_mrbgem   = "#{LOCAL_WASM_RUNTIME}/mrbgem"
runtime_dir  = File.expand_path("../runtime", __dir__)

MRuby::CrossBuild.new(build_name) do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
  shim_dir = "#{mwr_mrbgem}/hal-wasi-io/include"
  stub_flags = ["-isystem", shim_dir, "-include", "#{shim_dir}/wasi-shims.h"]
  # -Oz over -Os: ~5% smaller wasm; the compiled variant prioritizes
  # bundle size over throughput (apps are CLI-precompiled anyway).
  #
  # NOTE: `-flto` was previously included but caused the same setjmp
  # lowering bug documented in `lilac-full.rb` — the produced wasm
  # surfaces `LinkError: env.setjmp` at instantiation. Even though
  # `lilac-compiled` excludes `mruby-compiler` / `mruby-eval`, other
  # mruby internals (notably `mrb_protect` / `mrb_funcall` exception
  # paths) still go through setjmp, so the LTO interaction reproduces.
  # Re-enable if mruby / wasi-sdk fix the underlying pass ordering.
  size_flags = release ? ["-Oz"] : []

  conf.cc.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  conf.linker.flags << "-Wl,--allow-undefined"
  conf.linker.flags << "-Wl,--strip-debug" if release
  conf.linker.flags << "-mexec-model=reactor"

  conf.linker.libraries << "setjmp"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"
  # Tells callback.c to drop the mrb_load_string path and return 2 from
  # js_eval_handle. The JS bridge maps that to NotImplementedError.
  conf.cc.defines << "MRUBY_WASM_NO_COMPILER"

  # Minimum mrbgems Lilac relies on. mruby-compiler / mruby-eval are
  # deliberately omitted — apps must pre-compile their Ruby with `mrbc`.
  conf.gem core: "mruby-metaprog"    # Ref#method_missing, alias_method, extend
  conf.gem core: "mruby-fiber"       # Object#await, Resource fibers
  conf.gem core: "mruby-array-ext"   # Array#reverse_each, dup, compact
  conf.gem core: "mruby-hash-ext"    # Hash#each, dup
  conf.gem core: "mruby-string-ext"  # String#end_with?, tr, gsub, ...
  conf.gem core: "mruby-numeric-ext" # Integer#even?/#odd?/#step — parity with lilac-full
  conf.gem core: "mruby-enum-ext"    # Enumerable#each_with_object
  conf.gem core: "mruby-enumerator"  # Enumerator class
  conf.gem core: "mruby-kernel-ext"  # Kernel#raise variants, Object#tap
  conf.gem core: "mruby-object-ext"  # Object#instance_variable_*
  conf.gem core: "mruby-symbol-ext"  # Symbol#to_proc
  conf.gem core: "mruby-class-ext"   # Class#name (used in error messages)
  conf.gem core: "mruby-error"       # NoMethodError refinements
  conf.gem core: "mruby-sprintf"     # Kernel#sprintf, "%s" % ...

  conf.gem "#{mwr_mrbgem}/mruby-wasm-js"
  conf.gem "#{runtime_dir}/mruby-regexp-compat"  # Regexp class for user code & form validators
  conf.gem "#{runtime_dir}/mruby-lilac"
  conf.gem "#{runtime_dir}/mruby-lilac-form"   # Phase A: form is core

  conf.bins = []
end
