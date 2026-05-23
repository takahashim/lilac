# @takahashim/lilac-plugin-extras

Lilac plug-in package — ships pre-compiled `data-tooltip` and
`data-autofocus` directives as mruby bytecode.

Lilac's distribution model (decisions §24) keeps the `lilac-compiled`
core wasm small and pluggable: optional directive packs ride along as
separate npm packages whose pre-compiled `.mrb` bytecode is loaded into
the same VM at boot time. The runtime fallthrough (`scan_extensions`)
picks up the registered directives at each component's mount.

## Install

```sh
npm install @takahashim/lilac-compiled @takahashim/lilac-plugin-extras
```

The `lilac-compiled` core is a peer dependency. The same plug-in works
with `@takahashim/lilac-full` — both expose `boot({ plugins })`.

## Usage

```js
import { boot } from "@takahashim/lilac-compiled";
import { loadExtras } from "@takahashim/lilac-plugin-extras";

const [appMrb, extrasMrb] = await Promise.all([
  fetch("./app.mrb").then((r) => r.arrayBuffer()).then((b) => new Uint8Array(b)),
  loadExtras(),
]);

await boot({ bytecode: appMrb, plugins: [extrasMrb] });
```

The `plugins` array loads **before** the user bytecode, so the
`register_directive` calls take effect before any component mounts.

## Directives provided

| Directive | Behaviour |
|---|---|
| `data-tooltip="@signal"` | Binds the element's `title` attribute to the signal. |
| `data-autofocus` | Focuses the element after mount. |

See [Lilac directive spec](https://github.com/takahashim/lilac/blob/main/docs/lilac-directive-spec.md)
for the directive value grammar.

## Version compatibility

The plug-in `.mrb` is mruby-version-sensitive. Match a major/minor of
this package to the same major/minor of `@takahashim/lilac-compiled`.
Version mismatch surfaces as a `RubyError` from `vm.loadBytecode` at
boot time.

## License

MIT
