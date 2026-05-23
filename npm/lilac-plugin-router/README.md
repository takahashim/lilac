# @takahashim/lilac-plugin-router

Lilac plug-in package — ships `Lilac::Router` (signal-based URL
routing) as pre-compiled mruby bytecode.

`lilac-compiled` doesn't bundle the router gem to keep the core wasm
minimal (decisions §24). Apps that need routing install this plug-in
alongside `@takahashim/lilac-compiled` and load it at boot time.

`lilac-full` already includes the router gem in the wasm itself, so
this package isn't needed (and loading it would just redefine the
same constants).

## Install

```sh
npm install @takahashim/lilac-compiled @takahashim/lilac-plugin-router
```

## Usage

```js
import { boot } from "@takahashim/lilac-compiled";
import { loadRouter } from "@takahashim/lilac-plugin-router";

const [appMrb, routerMrb] = await Promise.all([
  fetch("./app.mrb").then((r) => r.arrayBuffer()).then((b) => new Uint8Array(b)),
  loadRouter(),
]);

await boot({ bytecode: appMrb, plugins: [routerMrb] });
```

The `plugins` array loads **before** the user bytecode, so
`Lilac::Router` is available by the time component code runs.

## What's provided

| Class | Purpose |
|---|---|
| `Lilac::Router` | Signal-backed router for `window.location` — driver class for SPA-style navigation. |

See [`lilac-router-spec.md`](https://github.com/takahashim/lilac/blob/main/docs/lilac-router-spec.md)
for the routing API.

## Version compatibility

The plug-in `.mrb` is mruby-version-sensitive. Match the
major/minor of this package to `@takahashim/lilac-compiled`.
Version mismatch raises a `RubyError` from `vm.loadBytecode` at boot
time.

## License

MIT
