# Lilac

A lightweight frontend framework for Ruby developers who are at
home with modern HTML and CSS, and would rather reach for Ruby
than JavaScript when adding behavior.

Templates stay as valid HTML5 with `data-*` directives — **no inline
expressions, no embedded code**. All logic lives in Ruby; reactivity
is driven by Signals and Effects; everything runs in the browser as
mruby compiled to WebAssembly via [mruby-wasm-runtime][mwr].

[mwr]: https://github.com/takahashim/mruby-wasm-runtime

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
`bind_list` calls automatically. See `examples/runtime-only/` for fuller demos
including `data-each` lists, forms, and shared theme state.

To run the examples locally:

```bash
make serve   # builds the wasm bundle, symlinks mrbgem, starts wsv
# then visit http://127.0.0.1:8000/examples/runtime-only/
```

## Build variants

| Variant | Compiler | Mrbgems | Use case |
|---|---|---|---|
| `lilac-full` | ✅ | core + directives + async + router + form + extras + regexp-compat | default, no-build, runtime scanner canonical |
| `lilac-compiled` | ❌ (apps must ship `mrbc`-compiled IREP via `lilac build`) | core + directives + form + regexp-compat | production size optimization (codegen canonical, scanner as runtime fallthrough for package directives) |

Add `-release` to any target for the optimised (`-Os --strip-debug`)
variant.

## Distribution

Lilac is distributed across **two channels** (ADR-25 / ADR-28):

| What | Channel | URL / package |
|---|---|---|
| `lilac-full.wasm` + boot helper (Mode 1 = CDN-only browser use) | GitHub Pages | `https://takahashim.github.io/lilac/v$VERSION/` *(after first release tag)* |
| `lilac-compiled.wasm` + bridge files (consumed by `lilac-cli`) | rubygems | `gem "lilac-wasm-bin"` *(release pending wasmtime-rb v45)* |
| `lilac-cli` CLI gem | rubygems | `gem "lilac-cli"` *(release pending wasmtime-rb v45)* |
| Package gems (extras / router / async / form) | rubygems | `gem "lilac-extras"` etc. *(release pending)* |

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
  (`components/` + `pages/`) with `<div data-use="..."></div>`
  placeholder composition.
- **Pre-compiled bindings** — directive interpretation moves from
  mount time to build time; the generated `Lilac::Bindings::<Class>`
  module's `bind_template_hook` takes precedence over the runtime
  scanner, so there's no double-binding when both paths coexist.
- **dev server** with live reload, `scaffold`, `doctor`.

See `cli/README.md` for usage details.

## Design decisions

Architecture-level rationales (= "why does it work this way?") live as
ADRs under [`docs/adr/`](./docs/adr/). The
[index](./docs/adr/README.md) lists each decision; per-ADR files
record the problem, the trade-offs considered, and the resulting
implementation. Speculative / unconfirmed proposals are tracked
separately in [`docs/lilac-proposals.md`](./docs/lilac-proposals.md).

## Tests

```bash
make test         # wasm_spec under wasmtime-rb + Dommy (Ruby-only, fast,
                  # no Node install needed). Default for the inner dev loop.
make test-node    # Same scenarios under Node + happy-dom (V8 cross-check).
                  # Used in CI; rarely needed in local development.
make test-cli     # Ruby CLI gem tests — fast, no wasm rebuild
make test-all     # CLI + Ruby wasm_spec + Node wasm_spec. Pre-release sweep.

# Equivalent low-level invocation for the CLI tests:
cd cli && bundle exec rake test
```

## License

MIT
