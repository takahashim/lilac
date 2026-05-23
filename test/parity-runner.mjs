// Parity test runner for `:full` vs `:compiled` build targets.
//
// For each fixture project under test/parity-fixtures/<name>/:
//   1. Build it with `lilac build --target full`     → dist/ has inline Ruby
//   2. Build it with `lilac build --target compiled` → dist/ has .mrb + boot
//   3. Load both into separate VMs (lilac-full.wasm + lilac-compiled.wasm)
//   4. Run a per-fixture scenario script of user actions + DOM snapshots
//   5. After every step, compare the two DOM trees byte-for-byte
//
// The goal is to prove Vite-style dev/prod parity: same `.lil` source,
// same DOM result regardless of target. Any discrepancy fails fast with
// the offending step + a side-by-side dump.

import { readFile, mkdtemp, cp, readdir, rm } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPO   = "/Users/maki/git/lilac";
const MWR    = process.env.MRUBY_WASM_RUNTIME_PATH || "/Users/maki/git/mruby-wasm-runtime";
// Default to release wasms (matches CI), but allow env override so
// contributors can iterate without paying the release rebuild cost.
const FULL_WASM     = process.env.LILAC_FULL_WASM     || `${REPO}/build/lilac-full.release.wasm`;
const COMPILED_WASM = process.env.LILAC_COMPILED_WASM || `${REPO}/build/lilac-compiled.release.wasm`;
const FIXTURES_DIR  = `${REPO}/test/parity-fixtures`;
const LILAC_BIN     = `${REPO}/cli/exe/lilac`;
const CLI_GEMFILE   = `${REPO}/cli/Gemfile`;
// Plug-in bytecode bundles available to fixtures. The compiled wasm
// no longer links these gems directly (decisions §24/§25). With the
// pivot to gem-based distribution (§25), npm no longer publishes the
// `.mrb`; the parity-runner instead builds it on the fly via
// `lilac plugin-build` so the test stays self-contained. The resulting
// path is wired into `SCENARIOS.extras.plugins` via `buildExtrasMrb()`
// during `main()`.
let EXTRAS_MRB = null;

// Per-fixture scenario. Each entry returns:
//   { steps: Array<Step>,          // sequence of actions to perform
//     snapshot: (doc) => string }  // how to capture state for comparison
//
// `mount_html` is taken from each target's built dist (= same source
// of truth the runtime would see), then everything BUT the inline
// <script type="text/ruby"> tag is kept as the DOM seed.
//
// Step = { label, run(doc) => void }
const SCENARIOS = {
  counter: {
    component_selector: '[data-component="counter"]',
    steps: [
      { label: "initial mount" },
      { label: "click inc",     run: (doc) => doc.querySelector('[data-ref="inc"]').click() },
      { label: "click inc x3",  run: (doc) => { for (let i=0; i<3; i++) doc.querySelector('[data-ref="inc"]').click(); } },
      { label: "click dec x2",  run: (doc) => { for (let i=0; i<2; i++) doc.querySelector('[data-ref="dec"]').click(); } },
    ],
    snapshot: (doc) => doc.querySelector('[data-component="counter"]').outerHTML,
  },

  toggle: {
    component_selector: '[data-component="toggle"]',
    steps: [
      { label: "initial mount (flag=false)" },
      { label: "click toggle (true)",  run: (doc) => doc.querySelector('[data-ref="toggle_btn"]').click() },
      { label: "click toggle (false)", run: (doc) => doc.querySelector('[data-ref="toggle_btn"]').click() },
      { label: "click toggle (true)",  run: (doc) => doc.querySelector('[data-ref="toggle_btn"]').click() },
    ],
    snapshot: (doc) => doc.querySelector('[data-component="toggle"]').outerHTML,
  },

  form: {
    component_selector: '[data-component="login-form"]',
    steps: [
      { label: "initial mount (empty inputs)" },
      {
        label: "type email",
        run: (doc) => {
          const el = doc.querySelector('[data-ref="email_input"]');
          el.value = "alice@example.com";
          el.dispatchEvent(new doc.defaultView.Event("input", { bubbles: true }));
        },
      },
      {
        label: "type password",
        run: (doc) => {
          const el = doc.querySelector('[data-ref="pw_input"]');
          el.value = "secret";
          el.dispatchEvent(new doc.defaultView.Event("input", { bubbles: true }));
        },
      },
      { label: "click submit (ok)", run: (doc) => doc.querySelector('[data-ref="submit"]').click() },
      {
        label: "clear email",
        run: (doc) => {
          const el = doc.querySelector('[data-ref="email_input"]');
          el.value = "";
          el.dispatchEvent(new doc.defaultView.Event("input", { bubbles: true }));
        },
      },
      { label: "click submit (missing)", run: (doc) => doc.querySelector('[data-ref="submit"]').click() },
    ],
    snapshot: (doc) => doc.querySelector('[data-component="login-form"]').outerHTML,
  },

  extras: {
    component_selector: '[data-component="tooltip-widget"]',
    // The compiled wasm has no extras gem linked — runtime plug-in load
    // is the only path. Full wasm still ships extras, so loading the
    // .mrb only on compiled keeps both paths exercised symmetrically.
    // `plugins:` is populated at runtime by `buildExtrasMrb()`.
    plugins: [],
    steps: [
      { label: "initial mount (first hint)" },
      { label: "click toggle (second hint)", run: (doc) => doc.querySelector('[data-ref="toggle"]').click() },
      { label: "click toggle (first hint)",  run: (doc) => doc.querySelector('[data-ref="toggle"]').click() },
    ],
    snapshot: (doc) => doc.querySelector('[data-component="tooltip-widget"]').outerHTML,
  },

  list: {
    component_selector: '[data-component="tag-list"]',
    steps: [
      { label: "initial mount (3 items)" },
      { label: "click add (4 items)",          run: (doc) => doc.querySelector('[data-ref="add"]').click() },
      { label: "click add again (5 items)",    run: (doc) => doc.querySelector('[data-ref="add"]').click() },
      { label: "click remove first (4 items)", run: (doc) => doc.querySelector('[data-ref="remove_first"]').click() },
      { label: "click reverse (4 items)",      run: (doc) => doc.querySelector('[data-ref="reverse"]').click() },
      { label: "click remove first x2 (2 items)", run: (doc) => { for (let i=0; i<2; i++) doc.querySelector('[data-ref="remove_first"]').click(); } },
    ],
    snapshot: (doc) => {
      // Normalise generated lil-N ref attrs which differ across paths.
      const html = doc.querySelector('[data-component="tag-list"]').outerHTML;
      return html.replace(/data-ref="lil\d+"/g, 'data-ref="lilN"');
    },
  },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function importMwrBridge() {
  const { createVM } = await import(pathToFileURL(`${MWR}/mrbgem/mruby-wasm-js/js/index.js`).href);
  return createVM;
}

function setupFetch() {
  globalThis.fetch = async (url) => {
    const path = fileURLToPath(new URL(url, import.meta.url));
    return new Response(await readFile(path), { headers: { "Content-Type": "application/wasm" } });
  };
}

// Build a fresh extras `.mrb` via `lilac plugin-build` so the parity
// test exercises the same code path users hit at build time (concat
// mrblib → mrbc backend). Returns the absolute path to the produced
// bytecode file under a per-run tmpdir.
async function buildExtrasMrb() {
  const dest = await mkdtemp(join(tmpdir(), "lilac-parity-extras-mrb-"));
  const out = join(dest, "extras.mrb");
  const mrblib = `${REPO}/runtime/mruby-lilac-extras/mrblib`;
  const sources = [
    `${mrblib}/lilac_extras.rb`,
    `${mrblib}/lilac_extras_focus.rb`,
    `${mrblib}/lilac_extras_tooltip.rb`,
  ];
  const r = spawnSync(LILAC_BIN, ["plugin-build", ...sources, "-o", out], {
    env: { ...process.env, MRUBY_WASM_RUNTIME_PATH: MWR, BUNDLE_GEMFILE: CLI_GEMFILE },
    encoding: "utf-8",
  });
  if (r.status !== 0) {
    throw new Error(`lilac plugin-build failed: ${r.stderr || r.stdout}`);
  }
  return out;
}

async function lilacBuild(fixtureSrc, target) {
  const dest = await mkdtemp(join(tmpdir(), `lilac-parity-${target}-`));
  await cp(fixtureSrc, dest, { recursive: true });
  const r = spawnSync(LILAC_BIN, ["build", "--target", target], {
    cwd: dest,
    env: { ...process.env, MRUBY_WASM_RUNTIME_PATH: MWR, BUNDLE_GEMFILE: CLI_GEMFILE },
    encoding: "utf-8",
  });
  if (r.status !== 0) {
    throw new Error(`lilac build --target ${target} failed in ${dest}: ${r.stderr || r.stdout}`);
  }
  return dest;
}

// Read the dist HTML and split it into:
//   bodyMarkup — the contents of <body> with all <script> blocks
//                stripped (= DOM seed)
//   scripts    — array of inline Ruby strings from <script type="text/ruby">
async function readDist(distDir) {
  const html = await readFile(join(distDir, "dist", "index.html"), "utf-8");
  const scripts = [...html.matchAll(/<script type="text\/ruby">([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const bodyMatch = html.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
  const inner = bodyMatch ? bodyMatch[1] : html;
  const bodyMarkup = inner.replace(/<script[\s\S]*?<\/script>/gi, "");
  return { bodyMarkup, scripts };
}

async function loadFull(createVM, dist) {
  const vm = await createVM({ wasm: `file://${FULL_WASM}` });
  for (const src of dist.scripts) vm.eval(src);
  return vm;
}

async function loadCompiled(createVM, distDir, pluginMrbPaths = []) {
  const files = await readdir(join(distDir, "dist"));
  const mrbFile = files.find((f) => f.endsWith(".mrb"));
  if (!mrbFile) throw new Error(`no .mrb in ${distDir}/dist`);
  const bytecode = new Uint8Array(await readFile(join(distDir, "dist", mrbFile)));
  const vm = await createVM({ wasm: `file://${COMPILED_WASM}` });
  // Pre-load plug-in bytecode before user code so `register_directive`
  // calls take effect before component mount. Mirrors the production
  // `boot({ plugins })` path in `npm/lilac-compiled/index.js`.
  for (const pluginPath of pluginMrbPaths) {
    const pluginBytes = new Uint8Array(await readFile(pluginPath));
    vm.loadBytecode(pluginBytes);
  }
  vm.loadBytecode(bytecode);
  return vm;
}

async function freshDom(mountHtml) {
  const { Window } = await import("happy-dom");
  const dom = new Window({ url: "https://test.local/" });
  globalThis.document = dom.document;
  dom.document.body.innerHTML = mountHtml;
  return dom.document;
}

function diffSnapshots(a, b) {
  if (a === b) return null;
  // Find the first differing line/character for a helpful pointer.
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      const ctx = 30;
      const start = Math.max(0, i - ctx);
      return {
        offset: i,
        full: `pos=${i}\n  full   : ${JSON.stringify(a.slice(start, i + ctx))}\n  compiled: ${JSON.stringify(b.slice(start, i + ctx))}`,
      };
    }
  }
  return { offset: Math.min(a.length, b.length), full: `length mismatch: full=${a.length} compiled=${b.length}` };
}

async function runFixture(fixtureName, createVM) {
  const fixtureSrc = join(FIXTURES_DIR, fixtureName);
  const scenario = SCENARIOS[fixtureName];
  if (!scenario) throw new Error(`no scenario defined for ${fixtureName}`);

  process.stdout.write(`\n=== ${fixtureName} ===\n`);

  const fullDir     = await lilacBuild(fixtureSrc, "full");
  const compiledDir = await lilacBuild(fixtureSrc, "compiled");

  // Both targets are built from the same `.lil` source; the body
  // markup (after TemplateAST's synthetic-ref pass) should be
  // identical too. We assert that pre-flight so a difference in dist
  // HTML doesn't masquerade as a runtime bug.
  const fullDist     = await readDist(fullDir);
  const compiledDist = await readDist(compiledDir);
  if (fullDist.bodyMarkup.trim() !== compiledDist.bodyMarkup.trim()) {
    process.stdout.write("  ✗ dist body markup differs between targets (pre-flight)\n");
    process.stdout.write(`    full:\n${fullDist.bodyMarkup.trim()}\n`);
    process.stdout.write(`    compiled:\n${compiledDist.bodyMarkup.trim()}\n`);
    return 1;
  }

  let failures = 0;

  const mountHtml = fullDist.bodyMarkup;
  const fullDoc = await freshDom(mountHtml);
  const fullVm  = await loadFull(createVM, fullDist);
  await sleep(50);

  const compiledDoc = await freshDom(mountHtml);
  const compiledVm  = await loadCompiled(createVM, compiledDir, scenario.plugins || []);
  await sleep(50);

  for (const step of scenario.steps) {
    // Re-bind globalThis.document for each step so the step callback's
    // querySelector hits the correct DOM. We snapshot both docs while
    // their globals are still in scope.
    if (step.run) {
      globalThis.document = fullDoc;
      step.run(fullDoc);
      await sleep(50);

      globalThis.document = compiledDoc;
      step.run(compiledDoc);
      await sleep(50);
    }

    const a = scenario.snapshot(fullDoc);
    const b = scenario.snapshot(compiledDoc);
    const diff = diffSnapshots(a, b);
    if (diff) {
      failures += 1;
      process.stdout.write(`  ✗ ${step.label}\n${diff.full}\n`);
    } else {
      process.stdout.write(`  ✓ ${step.label}\n`);
    }
  }

  await rm(fullDir,     { recursive: true, force: true });
  await rm(compiledDir, { recursive: true, force: true });

  return failures;
}

async function main() {
  setupFetch();
  const createVM = await importMwrBridge();

  // Build plug-in `.mrb` on the fly so the extras scenario has
  // something for its `loadBytecode` step. Skipped silently if the
  // scenario doesn't reference plug-ins.
  EXTRAS_MRB = await buildExtrasMrb();
  SCENARIOS.extras.plugins = [EXTRAS_MRB];

  let totalFail = 0;
  for (const name of Object.keys(SCENARIOS)) {
    try {
      totalFail += await runFixture(name, createVM);
    } catch (e) {
      console.error(`✗ ${name}: ${e.message}`);
      totalFail += 1;
    }
  }

  process.stdout.write("\n=== summary ===\n");
  if (totalFail === 0) {
    process.stdout.write(`All scenarios pass — :full and :compiled produce identical DOM.\n`);
    process.exit(0);
  } else {
    process.stdout.write(`${totalFail} failure(s)\n`);
    process.exit(1);
  }
}

main().catch((e) => { console.error(e); process.exit(2); });
