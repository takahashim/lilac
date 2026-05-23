// @takahashim/lilac-plugin-extras — Lilac plug-in shipping pre-compiled
// `data-tooltip` / `data-autofocus` directives as mruby bytecode.
//
// Usage with @takahashim/lilac-compiled:
//
//   import { boot } from "@takahashim/lilac-compiled";
//   import { loadExtras } from "@takahashim/lilac-plugin-extras";
//
//   const extrasMrb = await loadExtras();
//   await boot({ bytecode: appMrb, plugins: [extrasMrb] });
//
// The plug-in registers its directives via `register_directive` at load
// time, and the runtime's `scan_extensions` fallthrough (called from
// every component's `bind_template_hook`) picks them up at mount time.
// See decisions §23 (runtime fallthrough) and §24 (plug-in distribution).

/** URL to the bundled `.mrb` bytecode, resolvable from JS bundlers. */
export const extrasBytecodeUrl = new URL("./extras.mrb", import.meta.url);

/**
 * Fetch the plug-in bytecode and return it as a `Uint8Array`. Resolves
 * the bundled `extras.mrb` via `fetch` — works in browsers and modern
 * Node (>= 18). Pass the result to
 * `boot({ plugins: [await loadExtras()] })`.
 *
 * @returns {Promise<Uint8Array>}
 */
export async function loadExtras() {
  const res = await fetch(extrasBytecodeUrl);
  if (!res.ok) {
    throw new Error(
      `lilac-plugin-extras: failed to fetch extras.mrb (HTTP ${res.status})`,
    );
  }
  return new Uint8Array(await res.arrayBuffer());
}
