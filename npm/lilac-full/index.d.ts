// Type definitions for @takahashim/lilac-full

import type { createVM } from "@takahashim/mruby-wasm-js";

export { createVM } from "@takahashim/mruby-wasm-js";

export type LilacVM = Awaited<ReturnType<typeof createVM>>;

export interface BootOptions {
  /** Override the bundled wasm URL. Defaults to this package's `./lilac.wasm`. */
  wasm?: string | URL;
  /** Pre-compiled mruby bytecode. Mutually exclusive with `source` / `script`. */
  bytecode?: Uint8Array | ArrayBuffer;
  /**
   * Pre-compiled plug-in bytecode (e.g. produced by `lilac plugin-build`).
   * Loaded in order, before the main source/bytecode, so
   * `register_directive` calls take effect before user code runs.
   */
  plugins?: ReadonlyArray<Uint8Array | ArrayBuffer>;
  /** Ruby source string to evaluate. Mutually exclusive with `bytecode` / `script`. */
  source?: string;
  /**
   * Already-located `<script>` element, or its `id`/CSS selector.
   * Defaults to the first `<script type="text/ruby">`.
   */
  script?: HTMLScriptElement | string;
  /** CSS selector for the script tag. Falls back to `script[type='text/ruby']`. */
  scriptSelector?: string;
  /** Callback fired after the script is evaluated. */
  onReady?: (vm: LilacVM) => void | Promise<void>;
}

export function boot(opts?: BootOptions): Promise<LilacVM>;
