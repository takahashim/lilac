# mruby cross-build for the Grainet "full" variant — compiler + all
# Grainet gems (core / async / router / form). Produces
# `mruby-js-grainet-full.wasm`.
#
# Sibling configs in this repo:
#   build_config/wasi-js-grainet-min.rb    — no compiler, Grainet core only
#   build_config/wasi-js-grainet-small.rb  — compiler, Grainet core only
#
# Build mode (debug vs release) is selected via MRUBY_WASM_RELEASE.
#
# DEPENDENCY: mruby-wasm-runtime
#
# Grainet's wasm bundle includes the `mruby-wasm-js` JS↔mruby bridge
# and a handful of WASI shim mrbgems (`hal-wasi-io`, `mruby-wasi-dir`,
# `mruby-wasi-env`) that live in the separate mruby-wasm-runtime repo.
# Point `MRUBY_WASM_RUNTIME_PATH` at a local clone:
#
#   export MRUBY_WASM_RUNTIME_PATH=~/git/mruby-wasm-runtime
#
# With direnv installed, the repo's `.envrc` sets this automatically
# when you `cd grainet/`.
#
# TODO: support `conf.gem github: 'takahashim/mruby-wasm-runtime', path: ...`
# as a fallback. Blocker: hal-wasi-io currently exposes its POSIX shim
# headers via build_config-side `-isystem` / `-include` flags (see
# `stub_flags` below). Once hal-wasi-io self-contains those include
# paths in its own mrbgem.rake, this build_config can drop the
# absolute path and the github: fallback becomes straightforward.

LOCAL_WASM_RUNTIME = ENV["MRUBY_WASM_RUNTIME_PATH"]
unless LOCAL_WASM_RUNTIME && File.directory?(LOCAL_WASM_RUNTIME)
  abort <<~MSG
    Grainet's build needs a local clone of mruby-wasm-runtime.

    Set MRUBY_WASM_RUNTIME_PATH to point at it:

      export MRUBY_WASM_RUNTIME_PATH=$(cd .. && pwd)/mruby-wasm-runtime

    Or `direnv allow` in this directory to pick up the bundled .envrc
    automatically.
  MSG
end

wasi_sdk = ENV.fetch("WASI_SDK_PATH") { abort "Set WASI_SDK_PATH" }
sysroot = "#{wasi_sdk}/share/wasi-sysroot"
clang = "#{wasi_sdk}/bin/clang"
ar = "#{wasi_sdk}/bin/llvm-ar"
target = "wasm32-wasip1"

release = ENV["MRUBY_WASM_RELEASE"] == "1"
build_name = release ? "wasi-js-grainet-full-release" : "wasi-js-grainet-full"

# Bridge mrbgems live in mruby-wasm-runtime; framework mrbgems live
# in this repo's runtime/ subdir.
mwr_mrbgem   = "#{LOCAL_WASM_RUNTIME}/mrbgem"
runtime_dir  = File.expand_path("../runtime", __dir__)

MRuby::CrossBuild.new(build_name) do |conf|
  conf.toolchain :clang

  conf.cc.command = clang
  conf.cxx.command = "#{wasi_sdk}/bin/clang++"
  conf.linker.command = clang
  conf.archiver.command = ar

  common_flags = ["--target=#{target}", "--sysroot=#{sysroot}"]
  # Lower setjmp/longjmp (used by mruby for exceptions and GC mark scan)
  # to legacy Wasm EH — accepted by all modern browsers and Node without
  # flags.
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
  # POSIX shim headers (mrbgem/hal-wasi-io/include/) for wasi-sysroot
  # gaps. See hal-wasi-io/README.md in mruby-wasm-runtime for details.
  shim_dir = "#{mwr_mrbgem}/hal-wasi-io/include"
  stub_flags = ["-isystem", shim_dir, "-include", "#{shim_dir}/wasi-shims.h"]
  size_flags = release ? ["-Os"] : []
  conf.cc.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  conf.linker.flags << "-Wl,--allow-undefined"
  conf.linker.flags << "-Wl,--strip-debug" if release
  conf.linker.flags << "-mexec-model=reactor"

  conf.linker.libraries << "setjmp"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.gembox "default-no-stdio"

  # WASI shims + IO mrbgems from mruby-wasm-runtime.
  # hal-wasi-io must come BEFORE mruby-io so the latter's HAL
  # auto-detector picks it instead of the hal-posix-io fallback.
  conf.gem "#{mwr_mrbgem}/hal-wasi-io"
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-random"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-metaprog"
  conf.gem "#{mwr_mrbgem}/mruby-wasm-js"
  conf.gem "#{mwr_mrbgem}/mruby-wasi-dir"
  conf.gem "#{mwr_mrbgem}/mruby-wasi-env"

  # Grainet framework mrbgems (this repo).
  conf.gem "#{runtime_dir}/mruby-grainet"
  conf.gem "#{runtime_dir}/mruby-grainet-async"
  conf.gem "#{runtime_dir}/mruby-grainet-router"
  conf.gem "#{runtime_dir}/mruby-grainet-form"

  conf.bins = []
end
