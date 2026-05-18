# Lilac

A lightweight frontend framework for Ruby developers who are at
home with modern HTML and CSS, and would rather reach for Ruby
than JavaScript when adding behavior.

Templates stay as valid HTML5 with `data-*` directives — **no inline
expressions, no embedded code**. All logic lives in Ruby; reactivity
is driven by Signals and Effects; everything runs in the browser as
mruby compiled to WebAssembly via [mruby-wasm-runtime][mwr].

[mwr]: https://github.com/takahashim/mruby-wasm-runtime

## Layout

```
lilac/
├── runtime/        # mrbgems compiled into the wasm bundle
│   ├── mruby-lilac/             # Component / Signal / Effect / Bindable
│   ├── mruby-lilac-directives/  # runtime data-* directive scanner
│   ├── mruby-lilac-async/       # Fetchy / Resource
│   ├── mruby-lilac-router/
│   ├── mruby-lilac-form/
│   └── mruby-regexp-compat/     # vendored Regexp engine
├── cli/            # Ruby gem (lilac-cli) — optional build / dev / scaffold / lint
│   ├── lib/lilac/cli/
│   ├── exe/lilac
│   └── lilac-cli.gemspec
├── build_config/   # mruby cross-build configs for the wasm bundles
├── docs/           # directive spec, framework design notes
├── examples/       # standalone Lilac apps
└── Makefile        # builds lilac-{full,compiled}.wasm
```

`mruby-wasm-runtime` is a **separate repo** that owns the underlying
mruby + WASI build and the `mruby-wasm-js` JS↔mruby bridge. Lilac
depends on it as a peer clone (see "Setup" below).

## Setup

```bash
# 1. Clone both repos as siblings
cd ~/git
git clone https://github.com/takahashim/mruby-wasm-runtime
git clone https://github.com/takahashim/lilac

# 2. Bootstrap mruby-wasm-runtime once (downloads wasi-sdk, clones mruby)
cd mruby-wasm-runtime
make wasi-sdk

# 3. Tell lilac where to find it. Two options:
#
#    (a) direnv (recommended) — `cd lilac && direnv allow`
#        picks up MRUBY_WASM_RUNTIME_PATH from .envrc automatically.
#
#    (b) Manual export:
#        export MRUBY_WASM_RUNTIME_PATH=~/git/mruby-wasm-runtime
#
# 4. Build the full Lilac wasm bundle
cd ../lilac
make lilac-full         # → build/lilac-full.wasm
```

## Quick start: open and run

Lilac runs in the browser with no build step. Author a single HTML
file with `data-*` directives and an inline `<script type="text/ruby">`:

```html
<!DOCTYPE html>
<html>
  <body>
    <div data-component="Counter">
      <button data-on-click="decrement">-</button>
      <span data-text="@count">0</span>
      <button data-on-click="increment">+</button>
    </div>

    <script type="text/ruby" id="ruby-source">
      class Counter < Lilac::Component
        def setup
          @count = signal(0)
        end
        def increment(_ev) = @count.update { |n| n + 1 }
        def decrement(_ev) = @count.update { |n| n - 1 }
      end
      Lilac.register "Counter", Counter
      Lilac.start
    </script>

    <script type="module">
      import { createVM } from "../mruby-wasm-runtime/mrbgem/mruby-wasm-js/js/index.js";
      const vm = await createVM({ wasm: "./build/lilac-full.wasm" });
      vm.evalScript("#ruby-source");
    </script>
  </body>
</html>
```

The runtime walks the DOM at mount time, parses each `data-*`
directive, and wires the equivalent `bind` / `bind_input` /
`bind_list` calls automatically. See `examples/` for fuller demos
including `data-each` lists, forms, and shared theme state.

To run the examples locally:

```bash
make serve   # builds the wasm bundle, symlinks mrbgem, starts wsv
# then visit http://127.0.0.1:8000/examples/
```

## Build variants

| Variant | Compiler | Mrbgems | Use case |
|---|---|---|---|
| `lilac-full` | ✅ | core + directives + async + router + form + regexp-compat | default, no-build, runtime canonical |
| `lilac-compiled` | ❌ (apps must ship `mrbc`-compiled IREP via `lilac build`) | core + form + regexp-compat | production size optimization |

Add `-release` to any target for the optimised (`-Os --strip-debug`)
variant.

## CLI (optional)

```bash
cd cli
bundle install
bundle exec exe/lilac --help
```

The CLI is an **optional optimization layer** for larger projects.
The runtime is the canonical interpreter of `data-*` directives —
you can ship a Lilac app as plain HTML (see Quick start above).

What the CLI adds on top:

- **Static lint** — undeclared signals, unused methods, banned
  attributes, grammar errors caught at build time with source
  positions (instead of at component mount time).
- **`.lil` single-file components** + project structure
  (`components/` + `pages/`) with `<lilac-component name="...">`
  placeholder composition.
- **Pre-compiled bindings** — directive interpretation moves from
  mount time to build time; the generated `Lilac::Bindings::<Class>`
  module's `bind_template_hook` takes precedence over the runtime
  scanner, so there's no double-binding when both paths coexist.
- **dev server** with live reload, `scaffold`, `doctor`.

See `cli/README.md` for usage details.

## Tests

```bash
make test    # wasm_spec — exercises runtime/mruby-lilac*/wasm_spec/

cd cli && bundle exec rake test    # CLI unit tests (no wasm needed)
```

## Dependency on mruby-wasm-runtime

Lilac's wasm bundle bakes in two pieces from `mruby-wasm-runtime`:

- `mrbgem/mruby-wasm-js/` — the JS↔mruby bridge (callbacks, await,
  JS::Object), required for every Lilac runtime call.
- `mrbgem/hal-wasi-io/` + `mrbgem/mruby-wasi-{dir,env}/` — WASI shims
  / Ruby surface for filesystem / env access.

During the pre-1.0 phase, Lilac tracks `mruby-wasm-runtime/main` and
the local clone must be present (the build_config `abort`s without
`MRUBY_WASM_RUNTIME_PATH` set). Once mruby-wasm-runtime cuts a stable
release tag, the dependency will pin via `conf.gem github:` and the
local clone becomes optional.

## License

MIT
