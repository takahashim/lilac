# {{name}}

A Lilac app — Ruby in the browser via [mruby-wasm-runtime][1], composed
from `.llc` single-file components by [lilac-cli][2].

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
mkdir -p public/vendor/mruby-wasm-js
cp /path/to/mruby-wasm-runtime/build/mruby-js-lilac-full.wasm \
   public/vendor/mruby-js-lilac-full.wasm
cp -r /path/to/mruby-wasm-runtime/mrbgem/mruby-wasm-js/js/* \
       public/vendor/mruby-wasm-js/
```

Add anything else you want passthrough-served (favicons, images, CSS
without templating) directly under `public/`.

## Development

```sh
bundle exec lilac dev
```

Open <http://localhost:5173>. Edit any `.llc` component or `.html` page and
the browser reloads automatically (Server-Sent Events).

## Build for production

```sh
bundle exec lilac build
```

Output goes to `dist/`, which is self-contained (HTML + everything from
`public/`). Deploy `dist/` as your static site root.

## Configuration

`lilac.config.rb` at the project root overrides built-in defaults
for paths, host, and port. Every field is commented out by default;
uncomment what you want to change. CLI flags (`lilac dev --port`)
still take precedence over the file.

## Components and `data-*` directives

Templates wire DOM to reactive state via `data-*` attributes; the
build extracts them and generates the equivalent Ruby bindings
alongside your `<script>`, so the script holds only component logic.
The scaffold's `components/counter.llc` shows the most common ones:

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
| `data-value="@x"` / `data-checked="@x"` | two-way form-control binding |
| `data-show="@x"` / `data-hide="@x"` | visibility (toggles `.llc-hidden`) |
| `data-class="{ active: @x, 'btn-primary': @y }"` | class toggles (bare ident or quoted key) |
| `data-attr-href="@x"` | reactive HTML attribute (URLs auto-sanitized) |
| `data-css-color="@x"` | reactive CSS custom property (`--color`) |
| `data-on-click="m"` / `data-on-<event>="m"` | event handler → method on the component |
| `data-each="@items" data-key="id"` | keyed list iteration |

Values must be `@ivar` (a signal) or, inside `data-each`, `it` /
`it.field`. Arbitrary Ruby expressions are rejected at build time so
templates stay statically auditable.

Build-time also runs a cross-reference linter that warns when a
template references an undeclared `@signal` or `data-on-X` method
(stderr, non-fatal). Typos get a "Did you mean?" suggestion based on
edit distance against the declared names.
