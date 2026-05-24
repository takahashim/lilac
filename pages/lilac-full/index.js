// lilac-full — Lilac full variant boot helper for browser CDN delivery.
//
// Loads the bundled wasm (runtime parser + directive scanner + async /
// router / form / regexp-compat) and a `boot()` helper that wires it up
// to a `<script type="text/ruby">` tag. Ships via GitHub Pages at
// https://takahashim.github.io/lilac/v$VERSION/ — load via:
//
//   <script type="module">
//     import { boot } from "https://takahashim.github.io/lilac/v0.1.0/index.js";
//     await boot();
//   </script>
//
// `boot()` defaults to loading the co-located wasm and evaluating the
// first `<script type="text/ruby">` after DOMContentLoaded. It then
// fires `Lilac.start` to mount every `data-component` element
// (ADR-20.6 / ADR-20.7 — Pattern A boot helpers own the framework
// boot). The runtime-side `Lilac::Registry#start` is idempotent so
// user code that calls `Lilac.start` explicitly stays correct.
//
// Bridge files (mruby-wasm-js/index.js etc.) are co-located in the
// same versioned directory so all imports stay relative — no package
// manager or import map needed.

export { createVM } from "./mruby-wasm-js/index.js";
import { createVM } from "./mruby-wasm-js/index.js";

const DEFAULT_WASM_URL = new URL("./lilac.wasm", import.meta.url);
const DEFAULT_SCRIPT_SELECTOR = "script[type='text/ruby']";

/**
 * Boot a Lilac app.
 *
 * @param {object} [opts]
 * @param {string | URL} [opts.wasm]
 *   Override the bundled wasm URL. Defaults to this build's
 *   co-located `./lilac.wasm`.
 * @param {Uint8Array | ArrayBuffer} [opts.bytecode]
 *   Pre-compiled mruby bytecode (`.mrb`). Mutually exclusive with
 *   `source` / `script`.
 * @param {string} [opts.source]
 *   Ruby source string to evaluate. Mutually exclusive with
 *   `bytecode` / `script`.
 * @param {HTMLScriptElement | string} [opts.script]
 *   Already-located `<script>` element (or its `id`/CSS selector).
 *   Defaults to the first `<script type="text/ruby">`.
 * @param {string} [opts.scriptSelector]
 *   CSS selector for the script tag. Falls back to
 *   `script[type='text/ruby']`.
 * @param {(vm: any) => void | Promise<void>} [opts.onReady]
 *   Callback fired after `Lilac.start` has booted the framework.
 *   Receives the VM. "Ready" means components are mounted and the
 *   page is interactive.
 * @param {boolean} [opts.autoStart=true]
 *   When `false`, skip the automatic `vm.eval("Lilac.start")` call.
 *   Use this only for tests or specialised pre-boot setup; normal
 *   usage relies on the helper firing boot itself (Pattern A —
 *   ADR-20.7).
 * @returns {Promise<any>} resolved with the VM.
 */
export async function boot(opts = {}) {
  if (!opts || typeof opts !== "object") {
    throw new TypeError("boot: opts must be an object");
  }

  const vm = await createVM({ wasm: opts.wasm || DEFAULT_WASM_URL });

  if (opts.bytecode !== undefined) {
    const bytes =
      opts.bytecode instanceof Uint8Array
        ? opts.bytecode
        : new Uint8Array(opts.bytecode);
    vm.loadBytecode(bytes);
  } else if (opts.source !== undefined) {
    if (typeof opts.source !== "string") {
      throw new TypeError("boot: `source` must be a string");
    }
    vm.eval(opts.source);
  } else {
    await waitForDocumentReady();
    const selector = opts.scriptSelector || DEFAULT_SCRIPT_SELECTOR;
    const node = resolveScriptNode(opts.script, selector);
    if (node) {
      vm.eval(node.textContent || "");
    }
  }

  // Boot the framework at the tail of the eval/load step so user code
  // stays purely declarative (ADR-20.6). Idempotent on the runtime
  // side, so explicit user `Lilac.start` calls remain safe.
  if (opts.autoStart !== false) {
    vm.eval("Lilac.start");
  }

  if (typeof opts.onReady === "function") {
    await opts.onReady(vm);
  }
  return vm;
}

function resolveScriptNode(scriptOpt, fallbackSelector) {
  if (typeof document === "undefined") return null;
  if (scriptOpt && typeof scriptOpt === "object" && "textContent" in scriptOpt) {
    return scriptOpt;
  }
  if (typeof scriptOpt === "string") {
    return document.querySelector(scriptOpt);
  }
  return document.querySelector(fallbackSelector);
}

function waitForDocumentReady() {
  if (typeof document === "undefined") return Promise.resolve();
  if (document.readyState === "loading") {
    return new Promise((resolve) => {
      document.addEventListener("DOMContentLoaded", () => resolve(), { once: true });
    });
  }
  return Promise.resolve();
}
