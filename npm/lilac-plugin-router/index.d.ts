// Type definitions for @takahashim/lilac-plugin-router

/** URL to the bundled `.mrb` bytecode. */
export const routerBytecodeUrl: URL;

/**
 * Fetch the plug-in bytecode and return it as a `Uint8Array`. Pass the
 * result to `boot({ plugins: [await loadRouter()] })` from
 * `@takahashim/lilac-compiled` (or `@takahashim/lilac-full`).
 */
export function loadRouter(): Promise<Uint8Array>;
