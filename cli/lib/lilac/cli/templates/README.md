# {{name}}

A Lilac app — Ruby in the browser via [mruby-wasm-runtime][1], composed
from `.lil` single-file components by [lilac-cli][2].

[1]: https://github.com/takahashim/mruby-wasm-runtime
[2]: https://github.com/takahashim/lilac-cli

## Setup

```sh
bundle install
```

Place the Lilac wasm runtime under `public/vendor/`. Everything in
`public/` is mirrored verbatim into `dist/` at build time (Vite /
Eleventy convention), so requests to `/vendor/...` resolve from there
both in dev (`lilac dev`) and in production (`lilac build`).

```sh
mkdir -p public/vendor/lilac-full/mruby-wasm-js
cp /path/to/lilac/build/lilac-full.wasm \
   public/vendor/lilac-full/lilac-full.wasm
cp -r /path/to/mruby-wasm-runtime/mrbgem/mruby-wasm-js/js/* \
       public/vendor/lilac-full/mruby-wasm-js/
```

Add anything else you want passthrough-served (favicons, images, CSS
without templating) directly under `public/`.

## Development

```sh
bundle exec lilac dev
```

Open <http://localhost:5173>. Edit any `.lil` component or `.html` page and
the browser reloads automatically (Server-Sent Events).

## Build for production

```sh
bundle exec lilac build                  # default --target full
bundle exec lilac build --target compiled
```

Output goes to `dist/`, which is self-contained (HTML + everything from
`public/`). Deploy `dist/` as your static site root.

### `--target compiled`

`--target compiled` precompiles Ruby into `.mrb` bytecode (smaller
bundle, no in-browser parser) and **automatically vendors the
`lilac-compiled` runtime** into `dist/vendor/lilac-compiled/`. You do
not need to copy anything into `public/vendor/lilac-compiled/` —
the CLI resolves the wasm + JS bridge from one of:

1. `--lilac-compiled-path` / `--mruby-wasm-js-path` CLI flags
2. `c.lilac_compiled_path` / `c.mruby_wasm_js_path` in `lilac.config.rb`
3. `LILAC_COMPILED_WASM` / `MRUBY_WASM_JS_PATH` env vars
4. The Lilac monorepo (if you're working inside this repo)
5. `node_modules/@takahashim/lilac-compiled` and
   `node_modules/@takahashim/mruby-wasm-js`

Most projects can simply `npm install @takahashim/lilac-compiled` (which
pulls in the bridge as a peer dependency) and the build picks it up
automatically.

## Configuration

`lilac.config.rb` at the project root overrides built-in defaults
for paths, host, and port. Every field is commented out by default;
uncomment what you want to change. CLI flags (`lilac dev --port`)
still take precedence over the file.

## Components and `data-*` directives

Templates wire DOM to reactive state via `data-*` attributes; the
build extracts them and generates the equivalent Ruby bindings
alongside your `<script>`, so the script holds only component logic.
The scaffold's `components/counter.lil` shows the most common ones:

```html
<button data-on-click="decrement" type="button">-</button>
<span   data-text="@count" class="count">0</span>
<button data-on-click="increment" type="button">+</button>
```

```ruby
class Counter < Lilac::Component
  def setup
    @count = signal(0)
  end
  def increment(_ev) = @count.update(&:succ)
  def decrement(_ev) = @count.update(&:pred)
end
```

Available directive families:

| Directive | Purpose |
|---|---|
| `data-text="@x"` / `data-unsafe-html="@x"` | element body (escaped / raw) |
| `data-show="@x"` / `data-hide="@x"` | visibility (toggles `.lil-hidden`) |
| `data-class="{ active: @x, 'btn-primary': @y }"` | class toggles (bare ident or quoted key) |
| `data-attr-href="@x"` | reactive HTML attribute (URLs auto-sanitized) |
| `data-css-color="@x"` | reactive CSS custom property (`--color`) |
| `data-on-click="m"` / `data-on-<event>="m"` | event handler → method on the component |
| `data-each="@items" data-key="id"` | keyed list iteration |
| `data-field="name"` / `data-button="name"` | input two-way binding / button action (form gem) |

Values must be `@ivar` (a signal) or, inside `data-each`, `it` /
`it.field`. Arbitrary Ruby expressions are rejected at build time so
templates stay statically auditable.

Build-time also runs a cross-reference linter that warns when a
template references an undeclared `@signal` or `data-on-X` method
(stderr, non-fatal). Typos get a "Did you mean?" suggestion based on
edit distance against the declared names.
