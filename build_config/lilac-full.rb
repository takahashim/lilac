# mruby cross-build for the Lilac "full" variant — compiler + all
# Lilac gems (core / directives / async / router / form). Produces
# `build/lilac-full.wasm`. Surfaces as `@takahashim/lilac-full` on
# npm (see npm/lilac-full/).
#
# Sibling config in this repo:
#   build_config/lilac-compiled.rb — no compiler, Lilac core + form
#   + Regexp; for apps pre-built with `lilac-cli`.
#
# Build mode (debug vs release) is selected via MRUBY_WASM_RELEASE.
#
# Gem selection policy: **explicit allow-list**, no gembox. This keeps
# the bundle to what Lilac actually exercises and lets `wasm-ld`'s
# `--gc-sections` strip everything else. Removed from the historical
# `default-no-stdio` gembox: math.gembox (mruby-math / -rational /
# -complex / -bigint), mruby-set, mruby-objectspace, mruby-enum-lazy,
# mruby-enum-chain, mruby-random — none are referenced by Lilac runtime
# or any example (verified with grep + wasm_spec). mruby-time was
# removed at the same time but reinstated 2026-05-21 so examples like
# flight-booker can use `Time.now.strftime` instead of
# `JS.eval_javascript("new Date().toISOString()")`.
#
# Also dropped for the browser variant: mruby-io / hal-wasi-io /
# mruby-wasi-dir / mruby-wasi-env. Lilac runtime / examples don't use
# File / IO / Dir / ENV in the browser; the default logger now writes
# to `console.warn` / `console.error` via the JS bridge instead of
# STDERR. Additional saving: ~110 KB raw / ~30 KB brotli on top of
# the stdlib trim (verified 2026-05-19).
#
# DEPENDENCY: mruby-wasm-runtime
#
# Lilac's wasm bundle includes the `mruby-wasm-js` JS↔mruby bridge
# and a handful of WASI shim mrbgems (`hal-wasi-io`, `mruby-wasi-dir`,
# `mruby-wasi-env`) that live in the separate mruby-wasm-runtime repo.
# Point `MRUBY_WASM_RUNTIME_PATH` at a local clone:
#
#   export MRUBY_WASM_RUNTIME_PATH=~/git/mruby-wasm-runtime
#
# With direnv installed, the repo's `.envrc` sets this automatically
# when you `cd lilac/`.
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
    Lilac's build needs a local clone of mruby-wasm-runtime.

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
# `host` variant: new EH proposal lowering (try_table) for wasmtime-rb
# consumption. Browser path keeps legacy EH because Node + experimental
# flags aren't a default we want to require. See test/ruby_spec/.
host_variant = ENV["MRUBY_WASM_EH"] == "new"
build_name =
  if host_variant
    release ? "lilac-full-host-release" : "lilac-full-host"
  else
    release ? "lilac-full-release" : "lilac-full"
  end

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
  # to Wasm EH. The browser path stays on legacy EH (try / catch) so it
  # works in current Node (used by `make test`) without
  # --experimental-wasm-exnref. The `host` variant flips to the new
  # proposal (try_table) because wasmtime-rb's default config rejects
  # legacy EH.
  sjlj_flags = ["-mllvm", "-wasm-enable-sjlj"]
  sjlj_flags += ["-mllvm", "-wasm-use-legacy-eh=false"] if host_variant
  # POSIX shim headers (mrbgem/hal-wasi-io/include/) for wasi-sysroot
  # gaps. See hal-wasi-io/README.md in mruby-wasm-runtime for details.
  shim_dir = "#{mwr_mrbgem}/hal-wasi-io/include"
  stub_flags = ["-isystem", shim_dir, "-include", "#{shim_dir}/wasi-shims.h"]
  # `-Oz` over `-Os`: a few % smaller wasm; the framework is not CPU-bound
  # (interop crossings dominate), so optimizing harder for size pays off.
  #
  # NOTE: `-flto` is intentionally NOT included for the `full` variant.
  # The mruby-compiler / mruby-eval gems (which `lilac-compiled` excludes)
  # exercise setjmp/longjmp paths that hit a code-gen bug under LTO + the
  # `-mllvm -wasm-enable-sjlj` lowering — the resulting wasm either leaves
  # a stray `env::setjmp` import or throws an unhandled `WebAssembly.Exception`
  # at instantiation. The `lilac-compiled` variant (no compiler) is fine
  # with `-flto` and keeps it.
  size_flags = release ? ["-Oz"] : []
  conf.cc.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.cxx.flags.concat(common_flags + size_flags + sjlj_flags + stub_flags)
  conf.linker.flags.concat(common_flags)

  conf.linker.flags << "-Wl,--allow-undefined"
  conf.linker.flags << "-Wl,--strip-debug" if release
  conf.linker.flags << "-mexec-model=reactor"
  # The final wasm `--export=` flags (including the JS bridge trio and
  # mruby-host-compile's compile_source / mrbc_alloc / mrbc_free) are
  # driven by the Makefile's `LINK_JS_WASM` macro, not by these
  # build_config linker flags — `MRuby::CrossBuild` produces
  # libmruby.a, the wasm linking step happens in the outer Makefile.

  conf.linker.libraries << "setjmp"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # `mruby-compiler` + `mruby-eval` are pulled in transitively by
  # `mruby-wasm-js` (its `add_dependency` is gated on
  # MRUBY_WASM_NO_COMPILER, which lilac-full does not set). That's
  # what makes the "full" variant able to `vm.eval(rubyString)` at
  # runtime; `lilac-compiled.rb` sets MRUBY_WASM_NO_COMPILER=1 to
  # opt out and ship a smaller bundle (see Makefile).

  # stdlib pick — only what Lilac runtime / examples actually use.
  # Selection verified by grep + wasm_spec; removed entries are listed
  # in the header comment.
  conf.gem core: "mruby-compar-ext"    # Comparable module extension
  conf.gem core: "mruby-enum-ext"      # Enumerable#each_with_object, etc.
  conf.gem core: "mruby-string-ext"    # String#strip, tr, gsub, ...
  conf.gem core: "mruby-numeric-ext"   # Numeric#step etc.
  conf.gem core: "mruby-array-ext"     # Array#sum, find, reverse_each
  conf.gem core: "mruby-hash-ext"      # Hash#each, dup, merge variants
  conf.gem core: "mruby-range-ext"     # Range#each, cover?
  conf.gem core: "mruby-proc-ext"      # Proc class extensions
  conf.gem core: "mruby-symbol-ext"    # Symbol#to_proc
  conf.gem core: "mruby-object-ext"    # Object#instance_variable_*, tap
  conf.gem core: "mruby-fiber"         # Reactive::TRACKER fiber-id key
  conf.gem core: "mruby-enumerator"    # Enumerator class
  conf.gem core: "mruby-toplevel-ext"  # toplevel main object methods
  conf.gem core: "mruby-kernel-ext"    # Kernel#raise variants
  conf.gem core: "mruby-class-ext"     # Class#name (used in errors)
  conf.gem core: "mruby-catch"         # throw/catch (resource teardown)
  conf.gem core: "mruby-time"          # Time class (avoids JS.eval_javascript for Date)
  conf.gem core: "mruby-strftime"      # Time#strftime

  # mruby-sprintf is required by Kernel#sprintf and `"%s" %` style
  # interpolation in user code. mruby-metaprog is the single doorway
  # for `instance_variable_get` (decisions §13 keeps metaprog access
  # centralized in directives evaluator).
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-metaprog"

  # JS bridge from mruby-wasm-runtime. NOTE: mruby-io / hal-wasi-io /
  # mruby-wasi-dir / mruby-wasi-env are intentionally omitted —
  # browsers don't expose File / Dir / ENV, and the default Logger
  # routes through `console.warn` / `console.error` instead of STDERR.
  # The `stub_flags` (POSIX shim include paths) above remain in case
  # any future mrbgem references symbols WASI-sysroot lacks.
  conf.gem "#{mwr_mrbgem}/mruby-wasm-js"

  # Lilac framework mrbgems (this repo).
  conf.gem "#{runtime_dir}/mruby-regexp-compat"
  conf.gem "#{runtime_dir}/mruby-lilac"
  conf.gem "#{runtime_dir}/mruby-lilac-directives"
  conf.gem "#{runtime_dir}/mruby-lilac-async"
  conf.gem "#{runtime_dir}/mruby-lilac-router"
  conf.gem "#{runtime_dir}/mruby-lilac-form"
  conf.gem "#{runtime_dir}/mruby-lilac-extras"

  # Exposes `compile_source` / `mrbc_alloc` / `mrbc_free` for the
  # lilac-cli wasm-driven build path (`WasmMrbcDriver`). Compiled
  # only into the `full` variant — `lilac-compiled` has no
  # `mruby-compiler`, so the export would always return status=2
  # there.
  conf.gem "#{runtime_dir}/mruby-host-compile"

  conf.bins = []
end
