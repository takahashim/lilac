// Runtime test for :bundle delivery (ADR-0030).
//
// The CLI side (emitted <link>, lilac.bundle.html, boot module) is
// covered by cli/test/test_builder.rb. This test covers the part those
// string assertions can't: the BOOT-TIME behavior — fetch the
// `<link rel="lilac-bundle">`, inject the bundle's <template> elements
// into the live document, then mount. It reproduces each target's boot
// sequence faithfully and asserts the data-use component mounts and
// stays reactive.
//
// Run with (new-EH wasm → exnref flag; point env at freshly-built wasm):
//   LILAC_FULL_WASM=$PWD/build/lilac-full.wasm \
//   LILAC_COMPILED_WASM=$PWD/build/lilac-compiled.wasm \
//     node --experimental-wasm-exnref test/bundle-runtime.mjs

import { readFile, mkdtemp, cp, writeFile } from "node:fs/promises";
import { pathToFileURL, fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const MWR  = process.env.MRUBY_WASM_RUNTIME_PATH || join(REPO, "..", "mruby-wasm-runtime");
const FULL_WASM     = process.env.LILAC_FULL_WASM     || `${REPO}/build/lilac-full.wasm`;
const COMPILED_WASM = process.env.LILAC_COMPILED_WASM || `${REPO}/build/lilac-compiled.wasm`;
const LILAC_BIN   = `${REPO}/cli/exe/lilac`;
const CLI_GEMFILE = `${REPO}/cli/Gemfile`;
const FIXTURE     = `${REPO}/test/parity-fixtures/counter`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// fetch polyfill: serve the built dist. The boot code fetches the wasm
// (file:// absolute, passed to createVM), the bundle ("/lilac.bundle.html"),
// and `.mrb` ("./app.X.mrb") — the latter two resolve against `distDir`.
function setupFetch(distDir) {
  globalThis.fetch = async (url) => {
    let path;
    if (url.startsWith("file://")) {
      path = fileURLToPath(new URL(url));
    } else {
      path = join(distDir, url.replace(/^\.?\//, ""));
    }
    // `application/wasm` so instantiateStreaming accepts the wasm fetch;
    // .html/.mrb consumers use text()/arrayBuffer() and ignore the type.
    return new Response(await readFile(path), { headers: { "Content-Type": "application/wasm" } });
  };
}

async function buildBundle(target) {
  const dest = await mkdtemp(join(tmpdir(), `lilac-bundle-${target}-`));
  await cp(FIXTURE, dest, { recursive: true });
  await writeFile(join(dest, "lilac.config.rb"),
    "Lilac::CLI.configure { |c| c.delivery = :bundle }\n");
  const r = spawnSync(LILAC_BIN, ["build", "--target", target], {
    cwd: dest,
    env: { ...process.env, MRUBY_WASM_RUNTIME_PATH: MWR, BUNDLE_GEMFILE: CLI_GEMFILE },
    encoding: "utf-8",
  });
  if (r.status !== 0) throw new Error(`build --target ${target} (bundle) failed: ${r.stderr || r.stdout}`);
  return join(dest, "dist");
}

async function freshDom(bodyMarkup) {
  const { Window } = await import("happy-dom");
  const dom = new Window({ url: "https://test.local/" });
  globalThis.document = dom.document;
  globalThis.DOMParser = dom.DOMParser;
  dom.document.body.innerHTML = bodyMarkup;
  return dom;
}

// Fetch the bundle and inject its <template> elements into the live
// document, mirroring what both targets' boot code does before mount.
//
// The shipped boot module uses `new DOMParser().parseFromString(...)`
// (a separate document) + `cloneNode(true)`. happy-dom drops a
// <template>'s `.content` fragment across that cross-document clone, so
// here we parse into a holder in the SAME document — the registry's
// `collect_definitions` reads `template.content`, which only survives
// same-document parsing under happy-dom. The contract under test
// (bundle templates → data-use expansion → mount) is identical either
// way; only the DOM-plumbing detail differs.
async function injectBundleTemplates() {
  for (const link of document.querySelectorAll('link[rel="lilac-bundle"]')) {
    const res = await fetch(link.getAttribute("href"));
    const holder = document.createElement("div");
    holder.innerHTML = await res.text();
    for (const tpl of [...holder.querySelectorAll("template")]) {
      document.body.appendChild(tpl);
    }
  }
}

function bodyMarkup(pageHtml) {
  const inner = (pageHtml.match(/<body[^>]*>([\s\S]*?)<\/body>/i) || [])[1] || pageHtml;
  // Drop the inline boot <script type="module"> — we reproduce its
  // steps here so the test doesn't depend on the bridge's relative
  // imports / top-level-await module resolution.
  const body = inner.replace(/<script[\s\S]*?<\/script>/gi, "");
  // The `<link rel="lilac-bundle">` lives outside <body> in the emitted
  // page; carry it into the seed so the boot's querySelectorAll finds it
  // (it scans the whole document, so a link inside <body> is fine).
  const link = (pageHtml.match(/<link[^>]*rel="lilac-bundle"[^>]*>/i) || [])[0] || "";
  return link + body;
}

let failures = 0;
function check(label, cond) {
  process.stdout.write(`  ${cond ? "✓" : "✗"} ${label}\n`);
  if (!cond) failures += 1;
}

async function importBridge() {
  const { createVM } = await import(pathToFileURL(`${MWR}/mrbgem/mruby-wasm-js/js/index.js`).href);
  return createVM;
}

// :full bundle — page carries only <link> + data-use; the boot helper
// fetches the bundle, injects templates, then evals the bundle's
// <script type="text/ruby"> (which ends with Lilac.start).
async function runFull(createVM) {
  process.stdout.write("\n=== :full × :bundle ===\n");
  const dist = await buildBundle("full");
  setupFetch(dist);
  const pageHtml = await readFile(join(dist, "index.html"), "utf8");
  await freshDom(bodyMarkup(pageHtml));
  await injectBundleTemplates();

  const bundleHtml = await readFile(join(dist, "lilac.bundle.html"), "utf8");
  const scripts = [...bundleHtml.matchAll(/<script type="text\/ruby">([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  const vm = await createVM({ wasm: `file://${FULL_WASM}` });
  for (const s of scripts) vm.eval(s);
  await sleep(80);

  assertMounted("full");
}

// :compiled bundle — page carries a self-contained boot module: fetch
// bundle, inject templates, then loadBytecode the mrb chain (bundle defs
// first, start mrb last).
async function runCompiled(createVM) {
  process.stdout.write("\n=== :compiled × :bundle ===\n");
  const dist = await buildBundle("compiled");
  setupFetch(dist);
  const pageHtml = await readFile(join(dist, "index.html"), "utf8");
  await freshDom(bodyMarkup(pageHtml));
  await injectBundleTemplates();

  // Preserve the boot module's load order.
  const mrbs = [...pageHtml.matchAll(/fetch\("\.\/([^"]+\.mrb)"\)/g)].map((m) => m[1]);
  check("boot module chains >= 1 .mrb", mrbs.length >= 1);
  const vm = await createVM({ wasm: `file://${COMPILED_WASM}` });
  for (const f of mrbs) vm.loadBytecode(new Uint8Array(await readFile(join(dist, f))));
  await sleep(80);

  assertMounted("compiled");
}

function assertMounted(target) {
  const use = document.querySelector('[data-use="counter"]');
  check(`[${target}] data-use mounted (has data-component-id)`,
    !!use && use.getAttribute("data-component-id") != null);
  // Definition came from the bundle; the data-component wrapper never
  // materializes in the live DOM (its children are hoisted into data-use).
  check(`[${target}] no live [data-component] wrapper`,
    document.querySelector('[data-component="counter"]') == null);
  const value = document.querySelector('[data-ref="value"]');
  check(`[${target}] bundle template rendered signal (@count=0)`,
    !!value && value.textContent.trim() === "0");
  // Reactivity through the bundle-delivered, scanner-bound directive.
  const inc = document.querySelector('[data-ref="inc"]');
  if (inc) inc.click();
}

async function main() {
  const createVM = await importBridge();
  await runFull(createVM);
  await sleep(80);
  // assert reactivity result for full
  check("[full] click inc → @count=1",
    document.querySelector('[data-ref="value"]')?.textContent.trim() === "1");

  await runCompiled(createVM);
  await sleep(80);
  check("[compiled] click inc → @count=1",
    document.querySelector('[data-ref="value"]')?.textContent.trim() === "1");

  process.stdout.write(`\n=== summary ===\n`);
  if (failures === 0) {
    process.stdout.write("bundle-delivery runtime OK — :full and :compiled boot, inject, mount, react.\n");
  } else {
    process.stdout.write(`${failures} failure(s)\n`);
    process.exit(1);
  }
}

await main();
