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
//
// `Lilac.start` is expected to be embedded in the supplied bytecode
// (decisions §20.6 caveat — the compiled wasm has no
// `mruby-compiler` / `mruby-eval`, so post-load `vm.eval("Lilac.start")`
// is unsupported). `lilac build --target compiled` appends it to the
// bundle automatically; callers that supply hand-rolled bytecode must
// either pre-compile a top-level `Lilac.start` call into the bundle
// or use a `loadBytecode` of a small pre-compiled boot stub themselves.

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
 * @param {Array<Uint8Array | ArrayBuffer>} [opts.plugins]
 *   Pre-compiled plug-in bytecode (e.g. produced by `lilac plugin-build`).
 *   Loaded **in order, before** `bytecode` so `register_directive` calls
 *   take effect before user component code mounts. See decisions §24
 *   for the plug-in distribution model.
 * @param {(vm: any) => void | Promise<void>} [opts.onReady]
 *   Callback fired after `loadBytecode` returns (boot is embedded in the
 *   bytecode for this variant — see file-level doc). Receives the VM.
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

  // Plug-ins first: their `register_directive` calls must run before
  // user component code so `scan_extensions` sees them at mount time.
  if (opts.plugins !== undefined) {
    if (!Array.isArray(opts.plugins)) {
      throw new TypeError("boot: `plugins` must be an array of bytecode buffers");
    }
    for (const p of opts.plugins) {
      vm.loadBytecode(p instanceof Uint8Array ? p : new Uint8Array(p));
    }
  }

  const bytes =
    opts.bytecode instanceof Uint8Array
      ? opts.bytecode
      : new Uint8Array(opts.bytecode);
  vm.loadBytecode(bytes);

  // No `vm.eval("Lilac.start")` here: the compiled wasm has no
  // parser, so `Lilac.start` must be present at the tail of the
  // bytecode itself (decisions §20.6 caveat). `lilac build` produces
  // bundles that already include it.
  if (typeof opts.onReady === "function") {
    await opts.onReady(vm);
  }
  return vm;
}
