// Lilac wasm_spec runner. Loads the lilac wasm bundle, runs
// spec_helper.rb from mruby-wasm-runtime, then each test_*.rb under
// runtime/mruby-lilac*/wasm_spec/.
//
// Resolves the mruby-wasm-runtime checkout via MRUBY_WASM_RUNTIME_PATH
// (same convention the build_config uses). The wasm path defaults to
// build/mruby-js-lilac-full.wasm; override with MRUBY_WASM_PATH.

import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const lilacRoot = resolve(here, "..");

const mwrPath = process.env.MRUBY_WASM_RUNTIME_PATH;
if (!mwrPath) {
  console.error("MRUBY_WASM_RUNTIME_PATH must point at a mruby-wasm-runtime checkout");
  process.exit(1);
}

const mwrJsUrl = pathToFileURL(
  resolve(mwrPath, "mrbgem/mruby-wasm-js/js/index.js"),
).href;
const { createVM, Directory, File, debug } = await import(mwrJsUrl);

if (process.env.MRUBY_WASM_TRACE) debug.trace = true;

globalThis.fetch = async (url) => {
  const path = fileURLToPath(new URL(url, import.meta.url));
  return new Response(await readFile(path), {
    headers: { "Content-Type": url.endsWith(".wasm") ? "application/wasm" : "text/plain" },
  });
};

// happy-dom for Lilac component specs. `Event` is intentionally not
// exposed to avoid shadowing Node's built-in; Ruby reaches happy-dom's
// classes via `document.defaultView`.
const { Window } = await import("happy-dom");
const dom = new Window({ url: "https://test.local/" });
globalThis.document = dom.document;
globalThis.localStorage = dom.localStorage;
globalThis.sessionStorage = dom.sessionStorage;
globalThis.requestAnimationFrame = dom.requestAnimationFrame.bind(dom);
globalThis.cancelAnimationFrame = dom.cancelAnimationFrame.bind(dom);
globalThis.window = dom;
globalThis.history = dom.history;
globalThis.location = dom.location;
globalThis.addEventListener = dom.addEventListener.bind(dom);
globalThis.removeEventListener = dom.removeEventListener.bind(dom);

const wasmUrl = process.env.MRUBY_WASM_PATH
  ? pathToFileURL(resolve(process.cwd(), process.env.MRUBY_WASM_PATH)).href
  : pathToFileURL(resolve(lilacRoot, "build/mruby-js-lilac-full.wasm")).href;

const vm = await createVM({
  wasm: wasmUrl,
  env: { SPEC_RUNNER: "wasm_spec" },
  args: ["mruby-lilac", "--smoke"],
  fs: new Directory({}),
});

const helperPath = resolve(mwrPath, "mrbgem/mruby-wasm-js/wasm_spec/spec_helper.rb");
console.log(`[runner] loading spec_helper.rb`);
vm.eval(await readFile(helperPath, "utf8"));

const specDirs = [
  ["mruby-regexp-compat",    resolve(lilacRoot, "runtime/mruby-regexp-compat/wasm_spec")],
  ["mruby-lilac",            resolve(lilacRoot, "runtime/mruby-lilac/wasm_spec")],
  ["mruby-lilac-directives", resolve(lilacRoot, "runtime/mruby-lilac-directives/wasm_spec")],
  ["mruby-lilac-async",      resolve(lilacRoot, "runtime/mruby-lilac-async/wasm_spec")],
  ["mruby-lilac-router",     resolve(lilacRoot, "runtime/mruby-lilac-router/wasm_spec")],
  ["mruby-lilac-form",       resolve(lilacRoot, "runtime/mruby-lilac-form/wasm_spec")],
  ["mruby-lilac-extras",     resolve(lilacRoot, "runtime/mruby-lilac-extras/wasm_spec")],
];

async function runDir(label, dir) {
  let entries;
  try {
    entries = await readdir(dir);
  } catch (_e) {
    return;
  }
  const testFiles = entries
    .filter((f) => f.startsWith("test_") && f.endsWith(".rb"))
    .sort();
  for (const f of testFiles) {
    const src = await readFile(join(dir, f), "utf8");
    console.log(`[runner] running ${label}/${f}`);
    const rc = vm.eval(src);
    if (rc !== 0) {
      console.error(`[runner] ${label}/${f} failed to load (parse/runtime error)`);
      process.exit(1);
    }
    await drainPendingFibers(label, f);
  }
}

// Each test file is wrapped in JS.__run_in_fiber__, so vm.eval returns
// as soon as the first .await yields. Without draining, queued work
// from one file leaks into the next and corrupts shared DOM state.
async function drainPendingFibers(label, f) {
  const maxIterations = 200;
  for (let i = 0; i < maxIterations; i++) {
    await new Promise((r) => setTimeout(r, 5));
    vm.eval("JS.global[:__await_fibers__] = JS.stats[:await_fibers]");
    const pending = Number(globalThis.__await_fibers__) || 0;
    if (pending === 0) return;
  }
  console.error(`[runner] ${label}/${f}: fibers still pending after ${maxIterations} iterations`);
}

for (const [label, dir] of specDirs) {
  await runDir(label, dir);
}

await new Promise((r) => setTimeout(r, 500));
vm.eval("Spec.summary");

const failed = !!globalThis.__test_failed__;
process.exit(failed ? 1 : 0);
