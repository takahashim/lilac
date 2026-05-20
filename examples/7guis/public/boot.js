// Shared boot script for every gallery page. Loaded as
//   <script type="module" src="/boot.js"></script>
//
// Picks up every <script type="text/ruby"> on the page (the page's own
// inline class definitions + the lilac-cli-injected component scripts),
// evaluates them inside a single VM in document order, and calls
// `Lilac.start` at the tail of the eval loop. Boot lives in this
// helper layer (decisions §20.6) so user Ruby stays purely declarative
// regardless of whether the page comes from `lilac build` or from
// hand-written runtime-only HTML — the canonical Lilac entry point
// for any Lilac-specific boot helper is "eval all script tags, then
// `Lilac.start`".
//
// `--target compiled` builds inject their own <script
// data-lilac-bootstrap> module that handles the load. In that case the
// runtime parser is unavailable (the compiled wasm has no parser) and
// the vendor/lilac-full/ tree is intentionally not shipped, so this
// script must bail out before its imports are evaluated. The early
// `data-lilac-bootstrap` check + dynamic `import()` keep the full-target
// path's `import` from being eagerly resolved against missing files.

const status = document.getElementById("boot");
const setStatus = (msg) => { if (status) status.textContent = msg; };

if (document.querySelector("[data-lilac-bootstrap]")) {
  // Compiled-target page; the injected bootstrap owns boot. The
  // page-inline <script type="text/ruby"> blocks were stripped at
  // build time and live inside the .mrb bytecode now, so the
  // source-mirror feature can't recover them.
  const sourceEl = document.getElementById("source-display");
  if (sourceEl) {
    sourceEl.textContent =
      "// Source is compiled into the .mrb bundle. Run the full target " +
      "to see the original Ruby here.";
  }
} else {
  try {
    setStatus("booting…");
    const { createVM } = await import("/vendor/lilac-full/mruby-wasm-js/index.js");
    const vm = await createVM({ wasm: "/vendor/lilac-full/lilac-full.wasm" });
    document.querySelectorAll('script[type="text/ruby"]')
      .forEach((s) => vm.eval(s.textContent));
    // Boot at the tail of the eval loop — the framework owns boot
    // dispatch (decisions §20.B). Runtime-side `Lilac::Registry#start`
    // is idempotent so users who additionally write `Lilac.start` in
    // their own Ruby code don't cause a double mount.
    vm.eval("Lilac.start");
    setStatus("ready");
  } catch (err) {
    console.error(err);
    setStatus("boot failed: " + err.message);
  }

  // Mirror the page's own inline Ruby into <code id="source-display">.
  // The first <script type="text/ruby"> in document order is always the
  // page's own block — lilac-cli appends shared component scripts after,
  // so `querySelector` (first match) hits the page-local source.
  const sourceEl = document.getElementById("source-display");
  if (sourceEl) {
    const rubyScript = document.querySelector('script[type="text/ruby"]');
    if (rubyScript) sourceEl.textContent = rubyScript.textContent.trim();
  }
}
