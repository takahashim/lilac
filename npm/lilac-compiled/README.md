# @takahashim/lilac-compiled

Lilac frontend framework — **compiled** variant. The smallest bundle,
intended for apps pre-compiled with [`lilac-cli`](https://rubygems.org/gems/lilac-cli)
(Ruby gem). About 50% smaller than `@takahashim/lilac-full`.

## What's inside

| Included | Excluded |
|---|---|
| Lilac core (Component / Signal / Effect / Bindable) | `mruby-compiler` / `mruby-eval` (= no runtime parser) |
| Lilac form gem | Lilac directive scanner |
| Lilac Regexp (mruby-regexp-compat) | Lilac async / router |
| Tightly-selected mruby core gems | WASI io (mruby-io / mruby-wasi-*) |

## Requirements

Apps shipped against this build **must be pre-compiled to mruby
bytecode** with `lilac-cli`. `vm.eval(source)` raises
`NotImplementedError` (the compiler isn't bundled). Use
`vm.loadBytecode(bytes)` with the `.mrb` produced by `lilac build`.

Runtime declarative directives (`data-text="@x"` etc.) are **not
scanned at runtime** in this variant. The CLI codegen path generates
explicit `Lilac::Bindings::Counter` modules that the user's class
includes — the included `bind_template_hook` then does all the
binding without a runtime scanner.

## Install

```sh
gem install lilac-cli
npm install @takahashim/lilac-compiled
```

## Usage

```js
import { boot } from "@takahashim/lilac-compiled";

// `bytecode` is required: load the .mrb produced by `lilac build`.
const bytecode = await fetch("./app.mrb")
  .then((r) => r.arrayBuffer())
  .then((b) => new Uint8Array(b));

await boot({ bytecode });
```

The bundled wasm is also available as a subpath export for advanced
use:

```js
import wasmUrl from "@takahashim/lilac-compiled/wasm";
```

For the no-build-step path (the runtime canonical Lilac story), use
[`@takahashim/lilac-full`](https://www.npmjs.com/package/@takahashim/lilac-full)
instead — it ships the full runtime scanner.

## License

MIT
