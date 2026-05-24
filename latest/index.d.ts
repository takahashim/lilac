// Type definitions for lilac-full (browser CDN delivery via GitHub Pages).

import type { createVM } from "./mruby-wasm-js/index.js";

export { createVM } from "./mruby-wasm-js/index.js";

export type LilacVM = Awaited<ReturnType<typeof createVM>>;

export interface BootOptions {
  /** Override the bundled wasm URL. Defaults to this build's co-located `./lilac.wasm`. */
  wasm?: string | URL;
  /** Pre-compiled mruby bytecode. Mutually exclusive with `source` / `script`. */
  bytecode?: Uint8Array | ArrayBuffer;
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
  /**
   * When `false`, skip the automatic `vm.eval("Lilac.start")` call.
   * Use this only for tests or specialised pre-boot setup.
   */
  autoStart?: boolean;
}

export function boot(opts?: BootOptions): Promise<LilacVM>;
