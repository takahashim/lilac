// Type definitions for @takahashim/lilac-plugin-async

/** URL to the bundled `.mrb` bytecode. */
export const asyncBytecodeUrl: URL;

/**
 * Fetch the plug-in bytecode and return it as a `Uint8Array`. Pass the
 * result to `boot({ plugins: [await loadAsync()] })` from
 * `@takahashim/lilac-compiled` (or `@takahashim/lilac-full`).
 */
export function loadAsync(): Promise<Uint8Array>;
