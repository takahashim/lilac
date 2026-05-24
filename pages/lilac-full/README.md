# lilac-full — CDN delivery via GitHub Pages

Lilac frontend framework — **full** variant. The standard, no-build
choice: Lilac core (Component / Signal / Effect / Bindable), runtime
directive scanner, async (Fetchy / Resource), router, form, and
Regexp. Write HTML + `<script type="text/ruby">` and open in a
browser — no build step required, no package manager.

This directory holds the **source** for what gets published to GitHub
Pages on each release tag (`v*`). The release workflow
(`.github/workflows/release.yml`) builds `lilac-full.wasm`, copies
these helper files alongside the wasm + the `mruby-wasm-js` bridge,
and pushes everything to `gh-pages` branch at
`/v$VERSION/`. The published URL is:

```
https://takahashim.github.io/lilac/v$VERSION/
```

## Usage (consumer side, after release)

```html
<!DOCTYPE html>
<html>
<body>
  <div data-component="Counter">
    <button data-on-click="increment">+1</button>
    <span data-text="@count"></span>
  </div>

  <script type="text/ruby">
    class Counter < Lilac::Component
      def setup; @count = signal(0); end
      def increment; @count.value += 1; end
    end
  </script>

  <script type="module">
    import { boot } from "https://takahashim.github.io/lilac/v0.1.0/index.js";
    await boot();
  </script>
</body>
</html>
```

`boot()` instantiates the bundled wasm, waits for `DOMContentLoaded`,
and evaluates the first `<script type="text/ruby">` in the document.
After eval it fires `Lilac.start` to mount every `data-component`
element (ADR-20.6 / 20.7 — Pattern A boot helpers own framework boot).

For finer control:

```js
import { boot, createVM } from "https://takahashim.github.io/lilac/v0.1.0/index.js";

// Evaluate a string directly.
await boot({ source: 'puts "hi"' });

// Pick a specific script tag.
await boot({ script: "#app-script" });

// Run code after the VM is ready.
await boot({ onReady: (vm) => vm.eval('Lilac.mount_all') });

// Drop the boot helper entirely, use createVM directly.
const vm = await createVM({ wasm: new URL("./lilac.wasm", import.meta.url) });
```

## Variants

| Variant | Built-in | Size (raw / brotli) | Use when |
|---|---|---|---|
| **`lilac-full` (this)** | runtime parser + directive scanner + everything | ~1.0 MB / ~322 KB | no-build path, default choice |
| `lilac-compiled` | minimal runtime; needs `lilac-cli` (Ruby gem) to pre-compile | ~530 KB / ~175 KB | production size optimization, CLI build pipeline |

`lilac-compiled` is distributed via the `lilac-wasm-bin` Ruby gem
(`bundle add lilac-wasm-bin`), not via CDN — see
[ADR-25](../../docs/adr/0025-pivot-plugin-distribution-to-rubygems.md)
for the rubygems-only distribution decision.

## License

MIT
