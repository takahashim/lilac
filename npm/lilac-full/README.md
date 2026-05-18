# @takahashim/lilac-full

Lilac frontend framework — **full** variant. The standard, no-build
choice: Lilac core (Component / Signal / Effect / Bindable), runtime
directive scanner, async (Fetchy / Resource), router, form, and
Regexp. Write HTML + `<script type="text/ruby">` and open in a
browser — no build step required.

## Install

```sh
npm install @takahashim/lilac-full
```

## Usage

```js
import { boot } from "@takahashim/lilac-full";

await boot();
```

`boot()` instantiates the bundled wasm, waits for `DOMContentLoaded`,
and evaluates the first `<script type="text/ruby">` in the document.

For finer control:

```js
import { boot, createVM } from "@takahashim/lilac-full";

// Evaluate a string directly.
await boot({ source: 'puts "hi"' });

// Pick a specific script tag.
await boot({ script: "#app-script" });

// Run code after the VM is ready.
await boot({ onReady: (vm) => vm.eval('Lilac.mount_all') });

// Drop the boot helper entirely, use createVM directly.
const vm = await createVM({ wasm: new URL("./lilac.wasm", import.meta.url) });
```

The bundled wasm is also available as a subpath export for bundlers
that want the URL directly:

```js
import wasmUrl from "@takahashim/lilac-full/wasm";
```

## Variants comparison

| Variant | Built-in | Size (raw / brotli) | Use when |
|---|---|---|---|
| `lilac-full` (this) | runtime parser + directive scanner + everything | ~1.0 MB / ~322 KB | no-build path, default choice |
| [`lilac-compiled`](https://www.npmjs.com/package/@takahashim/lilac-compiled) | minimal runtime; needs `lilac-cli` (Ruby gem) to pre-compile | ~530 KB / ~175 KB | production size optimization, CLI build pipeline |

## License

MIT
