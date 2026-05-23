// Type definitions for @takahashim/lilac-plugin-extras

/** URL to the bundled `.mrb` bytecode. */
export const extrasBytecodeUrl: URL;

/**
 * Fetch the plug-in bytecode and return it as a `Uint8Array`. Pass the
 * result to `boot({ plugins: [await loadExtras()] })` from
 * `@takahashim/lilac-compiled` (or `@takahashim/lilac-full`).
 */
export function loadExtras(): Promise<Uint8Array>;
