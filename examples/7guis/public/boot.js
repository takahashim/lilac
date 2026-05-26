// Shared boot script for every gallery page. Loaded as
//   <script type="module" src="/boot.js"></script>
//
// Picks up every <script type="text/ruby"> on the page (the page's own
// inline class definitions + the lilac-cli-injected component scripts),
// evaluates them inside a single VM in document order, and calls
// `Lilac.start` at the tail of the eval loop. Boot lives in this
// helper layer (decisions §20.6) so user Ruby stays purely declarative
// regardless of whether the page comes from `lilac build` or from
// hand-written runtime-only HTML.
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

// Both targets keep `<script type="text/ruby">` in the dist HTML
// (compiled mode only excludes the parser from the wasm, not the
// source from the page), so source-mirror works regardless of target.
const sourceEl = document.getElementById("source-display");
if (sourceEl) {
  const rubyScript = document.querySelector('script[type="text/ruby"]');
  if (rubyScript) sourceEl.textContent = rubyScript.textContent.trim();
}

if (!document.querySelector("[data-lilac-bootstrap]")) {
  // Target=full path: this script owns boot — load the runtime, eval
  // every text/ruby tag in document order, then fire Lilac.start.
  try {
    setStatus("booting…");
    const { createVM } = await import("/vendor/lilac-full/mruby-wasm-js/index.js");
    const vm = await createVM({ wasm: "/vendor/lilac-full/lilac-full.wasm" });

    // Fetch any <link rel="lilac-bundle"> resources before eval'ing
    // page scripts, so the bundle's templates land in the DOM and its
    // <script type="text/ruby"> get included in the eval loop below.
    for (const link of document.querySelectorAll('link[rel="lilac-bundle"]')) {
      const href = link.getAttribute("href");
      if (!href) continue;
      try {
        const res = await fetch(href);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const html = await res.text();
        const doc = new DOMParser().parseFromString(html, "text/html");
        // Append <template> + <script type="text/ruby"> to document.body
        // so the registry's collect_definitions + this script's eval
        // loop find them.
        for (const tpl of doc.querySelectorAll("template")) {
          document.body.appendChild(tpl.cloneNode(true));
        }
        for (const s of doc.querySelectorAll('script[type="text/ruby"]')) {
          const newScript = document.createElement("script");
          newScript.setAttribute("type", "text/ruby");
          newScript.textContent = s.textContent;
          document.body.appendChild(newScript);
        }
      } catch (err) {
        console.error(`[lilac] failed to load bundle ${href}:`, err);
      }
    }

    document.querySelectorAll('script[type="text/ruby"]')
      .forEach((s) => vm.eval(s.textContent));
    // Boot at the tail of the eval loop — the framework owns boot
    // dispatch (decisions §20.6). Runtime-side `Lilac::Registry#start`
    // is idempotent so users who additionally write `Lilac.start` in
    // their own Ruby code don't cause a double mount.
    vm.eval("Lilac.start");
    setStatus("ready");
  } catch (err) {
    console.error(err);
    setStatus("boot failed: " + err.message);
  }
}
