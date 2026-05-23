# @takahashim/lilac-plugin-async

Lilac plug-in package — ships async data primitives (`Fetchy`,
`Resource`, selector helpers) as pre-compiled mruby bytecode.

`lilac-compiled` doesn't bundle the async gem to keep the core wasm
minimal (decisions §24). Apps that need data fetching install this
plug-in alongside `@takahashim/lilac-compiled` and load it at boot
time.

`lilac-full` already includes the async gem in the wasm itself, so
this package isn't needed there (and loading it would just redefine
the same constants).

## Install

```sh
npm install @takahashim/lilac-compiled @takahashim/lilac-plugin-async
```

## Usage

```js
import { boot } from "@takahashim/lilac-compiled";
import { loadAsync } from "@takahashim/lilac-plugin-async";

const [appMrb, asyncMrb] = await Promise.all([
  fetch("./app.mrb").then((r) => r.arrayBuffer()).then((b) => new Uint8Array(b)),
  loadAsync(),
]);

await boot({ bytecode: appMrb, plugins: [asyncMrb] });
```

The `plugins` array loads **before** the user bytecode, so the
async classes are available by the time component code runs.

## What's provided

| Class | Purpose |
|---|---|
| `Fetchy` | HTTP client wrapping `window.fetch` with promise/`await` integration. |
| `Lilac::Resource` | Signal-backed async data source (re-fetches when source signals change). |
| Selector helpers | `selector` / `select` / `selector_of` for derived state. |

See [`fetchy-spec.md`](https://github.com/takahashim/lilac/blob/main/docs/fetchy-spec.md)
for the Fetchy API.

## Version compatibility

The plug-in `.mrb` is mruby-version-sensitive. Match the
major/minor of this package to `@takahashim/lilac-compiled`.
Version mismatch raises a `RubyError` from `vm.loadBytecode` at boot
time.

## License

MIT
