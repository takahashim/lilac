// @takahashim/lilac-compiled — Lilac compiled variant: wasm + boot helper.
//
// Bundles the compiled Lilac wasm (no runtime parser, no async/router,
// no WASI io) and a `boot()` helper. Apps shipped against this build
// MUST be pre-compiled to mruby bytecode with `lilac build` (Ruby gem).
//
//   import { boot } from "@takahashim/lilac-compiled";
//   const bytecode = await fetch("./app.mrb")
//     .then((r) => r.arrayBuffer())
//     .then((b) => new Uint8Array(b));
//   await boot({ bytecode });

export { createVM } from "@takahashim/mruby-wasm-js";
import { createVM } from "@takahashim/mruby-wasm-js";

const DEFAULT_WASM_URL = new URL("./lilac.wasm", import.meta.url);

/**
 * Boot a Lilac compiled-variant app.
 *
 * @param {object} opts
 * @param {string | URL} [opts.wasm]
 *   Override the bundled wasm URL. Defaults to this package's
 *   `./lilac.wasm`.
 * @param {Uint8Array | ArrayBuffer} opts.bytecode
 *   Pre-compiled mruby bytecode produced by `lilac build`. Required —
 *   this variant has no runtime parser, so `source` / `script` paths
 *   are rejected.
 * @param {(vm: any) => void | Promise<void>} [opts.onReady]
 *   Callback fired after the bytecode is loaded. Receives the VM.
 * @returns {Promise<any>} resolved with the VM.
 */
export async function boot(opts = {}) {
  if (!opts || typeof opts !== "object") {
    throw new TypeError("boot: opts must be an object");
  }
  if (
    opts.source !== undefined ||
    opts.script !== undefined ||
    opts.scriptSelector !== undefined
  ) {
    throw new TypeError(
      "boot: @takahashim/lilac-compiled has no runtime parser. " +
        "Use `bytecode` (pre-compiled via `lilac build`), or switch " +
        "to @takahashim/lilac-full to evaluate Ruby source at runtime.",
    );
  }
  if (opts.bytecode === undefined) {
    throw new TypeError(
      "boot: `bytecode` is required for @takahashim/lilac-compiled. " +
        "Compile your app with `lilac build` and pass the resulting .mrb bytes.",
    );
  }

  const vm = await createVM({ wasm: opts.wasm || DEFAULT_WASM_URL });

  const bytes =
    opts.bytecode instanceof Uint8Array
      ? opts.bytecode
      : new Uint8Array(opts.bytecode);
  vm.loadIrep(bytes);

  if (typeof opts.onReady === "function") {
    await opts.onReady(vm);
  }
  return vm;
}
