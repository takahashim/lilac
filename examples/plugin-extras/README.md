# examples/plugin-extras

Demonstrates Lilac's gem-based plug-in distribution
([decisions §25](../../docs/lilac-decisions.md)). The `lilac-compiled`
core wasm doesn't link the extras gem — `data-tooltip` and
`data-autofocus` work because `lilac build` discovers the
`lilac-plugin-extras` gem via Bundler, compiles its `mrblib/*.rb` to
bytecode, stages it under `dist/plugins/`, and the generated boot
script `loadBytecode`s it before the app's own bundle.

## Layout

```
examples/plugin-extras/
├── components/tooltip-demo.lil  ← uses data-tooltip + data-autofocus
├── pages/index.html             ← hosts <lilac-component>
├── lilac.config.rb              ← (no plug-in config — Bundler-driven)
├── Gemfile                      ← lilac-cli + lilac-plugin-extras
└── README.md
```

## Run

From this directory:

```sh
bundle install               # one-time
bundle exec lilac build      # builds dist/ for --target compiled (default)
bundle exec lilac preview    # serve dist/ on http://localhost:4173
```

The generated `dist/index.html` should contain:

```html
<script type="module" data-lilac-bootstrap>
  import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js";
  const vm = await createVM({ wasm: "./vendor/lilac-compiled/lilac.wasm" });
  vm.loadBytecode(new Uint8Array(await (await fetch("./plugins/lilac-plugin-extras.mrb")).arrayBuffer()));
  const bytecode = new Uint8Array(
    await (await fetch("./app.<hash>.mrb")).arrayBuffer()
  );
  vm.loadBytecode(bytecode);
</script>
```

The plug-in load line precedes the user bytecode load, which is what
makes `register_directive(:tooltip)` take effect before any component
mounts and dispatches `data-tooltip` through `scan_extensions`.

## `lilac dev` with plug-ins

Same Gemfile, `bundle exec lilac dev` (defaults to `--target full`).
The dist HTML stays the user-controlled `<script type="module">` boot;
lilac-cli writes a `dist/lilac.plugins.json` manifest the scaffold
boot fetches and `loadBytecode`s before evaluating `<script
type="text/ruby">` blocks. See `cli/lib/lilac/cli/templates/pages/
index.html` for the canonical boot.

## Outside the monorepo

Replace the monorepo-relative paths with released gem versions:

```ruby
# Gemfile
gem "lilac-cli", "~> 0.1"
gem "lilac-plugin-extras", "~> 0.1"
```

```sh
bundle install
bundle exec lilac build
```

No `c.plugins` config needed — Bundler auto-discovery picks the
plug-in up by its `metadata["lilac_plugin"] = "true"` flag.
