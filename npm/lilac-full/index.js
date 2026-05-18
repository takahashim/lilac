// @takahashim/lilac-full — Lilac full variant: wasm + boot helper.
//
// Bundles the full Lilac wasm (runtime parser + directive scanner +
// async/router/form/regexp-compat) and a `boot()` helper that wires
// it up to a `<script type="text/ruby">` tag.
//
//   import { boot } from "@takahashim/lilac-full";
//   await boot();
//
// `boot()` defaults to loading the bundled wasm and evaluating the
// first `<script type="text/ruby">` in the document after
// DOMContentLoaded.

export { createVM } from "@takahashim/mruby-wasm-js";
import { createVM } from "@takahashim/mruby-wasm-js";

const DEFAULT_WASM_URL = new URL("./lilac.wasm", import.meta.url);
const DEFAULT_SCRIPT_SELECTOR = "script[type='text/ruby']";

/**
 * Boot a Lilac app.
 *
 * @param {object} [opts]
 * @param {string | URL} [opts.wasm]
 *   Override the bundled wasm URL. Defaults to this package's
 *   `./lilac.wasm`.
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
 *   Callback fired after the script is evaluated. Receives the VM.
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
    vm.loadIrep(bytes);
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
