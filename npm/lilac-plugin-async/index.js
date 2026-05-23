// @takahashim/lilac-plugin-async — Lilac plug-in providing the async
// data primitives (`Fetchy`, `Resource`, selector helpers) as
// pre-compiled mruby bytecode for the `lilac-compiled` variant.
//
// Usage with @takahashim/lilac-compiled:
//
//   import { boot } from "@takahashim/lilac-compiled";
//   import { loadAsync } from "@takahashim/lilac-plugin-async";
//
//   const asyncMrb = await loadAsync();
//   await boot({ bytecode: appMrb, plugins: [asyncMrb] });
//
// `lilac-full` already ships these classes linked into the wasm, so
// loading this plug-in there is harmless but redundant.
//
// See decisions §24 (plug-in distribution model).

/** URL to the bundled `.mrb` bytecode, resolvable from JS bundlers. */
export const asyncBytecodeUrl = new URL("./async.mrb", import.meta.url);

/**
 * Fetch the plug-in bytecode and return it as a `Uint8Array`. Pass the
 * result to `boot({ plugins: [await loadAsync()] })`.
 *
 * @returns {Promise<Uint8Array>}
 */
export async function loadAsync() {
  const res = await fetch(asyncBytecodeUrl);
  if (!res.ok) {
    throw new Error(
      `lilac-plugin-async: failed to fetch async.mrb (HTTP ${res.status})`,
    );
  }
  return new Uint8Array(await res.arrayBuffer());
}
