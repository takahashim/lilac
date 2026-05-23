// @takahashim/lilac-plugin-router — Lilac plug-in providing the
// `Lilac::Router` class (signal-based URL routing) as pre-compiled
// mruby bytecode for the `lilac-compiled` variant.
//
// Usage with @takahashim/lilac-compiled:
//
//   import { boot } from "@takahashim/lilac-compiled";
//   import { loadRouter } from "@takahashim/lilac-plugin-router";
//
//   const routerMrb = await loadRouter();
//   await boot({ bytecode: appMrb, plugins: [routerMrb] });
//
// Unlike `lilac-plugin-extras`, this plug-in doesn't register any
// directives — it just makes `Lilac::Router` available as a Ruby
// class. User code does `router = Lilac::Router.new(...)` after the
// VM is booted.
//
// `lilac-full` already ships the router gem linked into the wasm, so
// loading this plug-in there is harmless (re-defining the same
// constants) but redundant.
//
// See decisions §24 (plug-in distribution model).

/** URL to the bundled `.mrb` bytecode, resolvable from JS bundlers. */
export const routerBytecodeUrl = new URL("./router.mrb", import.meta.url);

/**
 * Fetch the plug-in bytecode and return it as a `Uint8Array`. Pass the
 * result to `boot({ plugins: [await loadRouter()] })`.
 *
 * @returns {Promise<Uint8Array>}
 */
export async function loadRouter() {
  const res = await fetch(routerBytecodeUrl);
  if (!res.ok) {
    throw new Error(
      `lilac-plugin-router: failed to fetch router.mrb (HTTP ${res.status})`,
    );
  }
  return new Uint8Array(await res.arrayBuffer());
}
