// Type definitions for @takahashim/lilac-compiled

import type { createVM } from "@takahashim/mruby-wasm-js";

export { createVM } from "@takahashim/mruby-wasm-js";

export type LilacVM = Awaited<ReturnType<typeof createVM>>;

export interface BootOptions {
  /** Override the bundled wasm URL. Defaults to this package's `./lilac.wasm`. */
  wasm?: string | URL;
  /**
   * Pre-compiled mruby bytecode produced by `lilac build`. Required —
   * this variant has no runtime parser.
   */
  bytecode: Uint8Array | ArrayBuffer;
  /** Callback fired after the bytecode is loaded. */
  onReady?: (vm: LilacVM) => void | Promise<void>;
}

export function boot(opts: BootOptions): Promise<LilacVM>;
