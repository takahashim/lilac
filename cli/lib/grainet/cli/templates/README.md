# {{name}}

A Grainet app — Ruby in the browser via [mruby-wasm-runtime][1], composed
from `.gnt` single-file components by [grainet-cli][2].

[1]: https://github.com/takahashim/mruby-wasm-runtime
[2]: https://github.com/takahashim/grainet-cli

## Setup

```sh
bundle install
```

Place the Grainet wasm runtime under `public/vendor/`. Everything in
`public/` is mirrored verbatim into `dist/` at build time (Vite /
Eleventy convention), so requests to `/vendor/...` resolve from there
both in dev (`grainet dev`) and in production (`grainet build`).

```sh
mkdir -p public/vendor/mruby-wasm-js
cp /path/to/mruby-wasm-runtime/build/mruby-js-grainet-full.wasm \
   public/vendor/mruby-js-grainet-full.wasm
cp -r /path/to/mruby-wasm-runtime/mrbgem/mruby-wasm-js/js/* \
       public/vendor/mruby-wasm-js/
```

Add anything else you want passthrough-served (favicons, images, CSS
without templating) directly under `public/`.

## Development

```sh
bundle exec grainet dev
```

Open <http://localhost:5173>. Edit any `.gnt` component or `.html` page and
the browser reloads automatically (Server-Sent Events).

## Build for production

```sh
bundle exec grainet build
```

Output goes to `dist/`, which is self-contained (HTML + everything from
`public/`). Deploy `dist/` as your static site root.

## Configuration

`grainet.config.rb` at the project root overrides built-in defaults
for paths, host, and port. Every field is commented out by default;
uncomment what you want to change. CLI flags (`grainet dev --port`)
still take precedence over the file.
