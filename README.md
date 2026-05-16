# Grainet

Reactive single-file component framework for [mruby-on-wasm][mwr].
Templates use HTML5 `data-*` directives; build tool compiles `.gnt`
single-file components into static HTML + wasm.

[mwr]: https://github.com/takahashim/mruby-wasm-runtime

## Layout

```
grainet/
├── runtime/        # mrbgems compiled into the wasm bundle
│   ├── mruby-grainet/         # Component / Signal / Effect / Bindable
│   ├── mruby-grainet-async/   # Fetchy / Resource
│   ├── mruby-grainet-router/
│   └── mruby-grainet-form/
├── cli/            # Ruby gem (grainet-cli) — build / dev / scaffold / lint
│   ├── lib/grainet/cli/
│   ├── exe/grainet
│   └── grainet-cli.gemspec
├── build_config/   # mruby cross-build configs for the wasm bundles
├── docs/           # directive spec, framework design notes
├── examples/       # standalone Grainet apps
└── Makefile        # builds mruby-js-grainet-{full,small,min}.wasm
```

`mruby-wasm-runtime` is a **separate repo** that owns the underlying
mruby + WASI build and the `mruby-wasm-js` JS↔mruby bridge. Grainet
depends on it as a peer clone (see "Setup" below).

## Setup

```bash
# 1. Clone both repos as siblings
cd ~/git
git clone https://github.com/takahashim/mruby-wasm-runtime
git clone https://github.com/takahashim/grainet

# 2. Bootstrap mruby-wasm-runtime once (downloads wasi-sdk, clones mruby)
cd mruby-wasm-runtime
make wasi-sdk

# 3. Tell grainet where to find it. Two options:
#
#    (a) direnv (recommended) — `cd grainet && direnv allow`
#        picks up MRUBY_WASM_RUNTIME_PATH from .envrc automatically.
#
#    (b) Manual export:
#        export MRUBY_WASM_RUNTIME_PATH=~/git/mruby-wasm-runtime
#
# 4. Build the full Grainet wasm bundle
cd ../grainet
make js-grainet-full      # → build/mruby-js-grainet-full.wasm
```

## Build variants

| Variant | Compiler | Mrbgems | Use case |
|---|---|---|---|
| `js-grainet-min` | ❌ (apps must ship `mrbc`-compiled IREP) | core only | smallest production wasm |
| `js-grainet-small` | ✅ | core only | dev with eval, no async/router/form |
| `js-grainet-full` | ✅ | core + async + router + form | full-featured dev / production |

Add `-release` to any target for the optimised (`-Os --strip-debug`)
variant.

## CLI

```bash
cd cli
bundle install
bundle exec exe/grainet --help
```

The CLI lives in this repo at `cli/` (Ruby gem). It compiles `.gnt`
files into HTML + Ruby that the wasm runtime evaluates at component
mount time. See `cli/README.md` for usage / scaffold guide.

## Tests

```bash
make test    # wasm_spec — exercises runtime/mruby-grainet*/wasm_spec/

cd cli && bundle exec rake test    # CLI unit tests (no wasm needed)
```

## Dependency on mruby-wasm-runtime

Grainet's wasm bundle bakes in two pieces from `mruby-wasm-runtime`:

- `mrbgem/mruby-wasm-js/` — the JS↔mruby bridge (callbacks, await,
  JS::Object), required for every Grainet runtime call.
- `mrbgem/hal-wasi-io/` + `mrbgem/mruby-wasi-{dir,env}/` — WASI shims
  / Ruby surface for filesystem / env access.

During the pre-1.0 phase, Grainet tracks `mruby-wasm-runtime/main` and
the local clone must be present (the build_config `abort`s without
`MRUBY_WASM_RUNTIME_PATH` set). Once mruby-wasm-runtime cuts a stable
release tag, the dependency will pin via `conf.gem github:` and the
local clone becomes optional.

## License

MIT
