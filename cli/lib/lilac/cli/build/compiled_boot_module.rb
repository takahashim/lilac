# frozen_string_literal: true

module Lilac
  module CLI
    # Emits the `<script type="module">` boot stub for the `:compiled`
    # target: it loads `.mrb` bytecode, boots the lilac-compiled wasm,
    # and (in :bundle delivery) pulls the bundle's `<template>` elements
    # into the live document before `Lilac.start` runs.
    #
    # Split out of PageCompiler so the JS-string generation lives next to
    # HtmlEmitter's markup-emitting peers rather than mixing into the
    # per-page compile flow.
    module CompiledBootModule
      module_function

      # Decide the .mrb load order for a :compiled × :bundle page's boot
      # module. The bundle .mrb always loads first (component class
      # definitions, no `Lilac.start`). The tail is either the page-local
      # .mrb (which itself ends with `Lilac.start`) or the shared
      # `start-only.mrb` fallback so every page's chain terminates with
      # `Lilac.start`.
      def mrb_chain(bundle_assets, page_local_mrb)
        return [] unless bundle_assets

        chain = []
        chain << bundle_assets.bundle_mrb if bundle_assets.bundle_mrb
        if page_local_mrb
          chain << page_local_mrb
        elsif bundle_assets.bundle_mrb && bundle_assets.start_only_mrb
          chain << bundle_assets.start_only_mrb
        end
        chain
      end

      # Emits the module script that loads `.mrb` bytecode and boots
      # the lilac-compiled wasm. Inlines the boot logic instead of
      # depending on `@takahashim/lilac-compiled`'s published `index.js`
      # — the npm boot helper has occasionally drifted from the bridge's
      # current API (e.g. `loadIrep` rename → `loadBytecode`) and a
      # self-contained module is one fewer moving part to keep in sync.
      # The `data-lilac-bootstrap` attribute marks the tag so a future
      # asset-pipeline pass can rewrite the URLs.
      #
      # `Lilac.start` is NOT called here via `vm.eval`: the compiled
      # wasm excludes `mruby-compiler` / `mruby-eval`, so post-load
      # eval of arbitrary Ruby source is unsupported. Instead the
      # builder appends `Lilac.start` to the bundle so it runs as part
      # of `loadBytecode` (decisions §20.6 caveat).
      def render(mrb_filenames, package_urls: [], delivery: :inline)
        # Accept either a single filename or an array (used by the
        # :bundle delivery path to chain bundle.mrb + page-inline.mrb in
        # one VM).
        mrb_filenames = Array(mrb_filenames)

        # Package `.mrb` bundles load BEFORE the user bytecode so any
        # `Scanner.register("ClassName")` calls (and the Handler classes
        # they refer to) are ready by the time component mount runs.
        # Mirrors the load ordering in `npm/lilac-compiled/index.js`'s
        # boot helper.
        package_loads = package_urls.map do |url|
          "vm.loadBytecode(new Uint8Array(await (await fetch(#{url.inspect})).arrayBuffer()));"
        end
        bytecode_loads = mrb_filenames.map do |filename|
          %(vm.loadBytecode(new Uint8Array(await (await fetch("./#{filename}")).arrayBuffer())));
        end
        all_loads = (package_loads + bytecode_loads).join("\n  ")

        # :bundle delivery: the compiled wasm has no parser, so unlike
        # the :full boot helper we can't `vm.eval` bundle scripts —
        # those land in the chained .mrb above. But we still need to
        # pull the bundle's <template> elements into the live document
        # before `Lilac.start` runs (which is in the page-local /
        # start-only .mrb). Fetch + DOMParser the bundle and append
        # each <template>; scripts inside the bundle are intentionally
        # ignored (they don't exist for :compiled bundles).
        bundle_block =
          if delivery == :bundle
            <<~JS.chomp.gsub(/^/, '  ')
              for (const link of document.querySelectorAll('link[rel="lilac-bundle"]')) {
                const res = await fetch(link.getAttribute("href"));
                const doc = new DOMParser().parseFromString(await res.text(), "text/html");
                for (const tpl of doc.querySelectorAll("template")) {
                  document.body.appendChild(tpl.cloneNode(true));
                }
              }
            JS
          end

        body_parts = []
        body_parts << bundle_block if bundle_block
        body_parts << "  #{all_loads}" unless all_loads.empty?

        <<~HTML.strip
          <script type="module" data-lilac-bootstrap>
            import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js";
            const vm = await createVM({ wasm: "./vendor/lilac-compiled/lilac.wasm" });
          #{body_parts.join("\n")}
          </script>
        HTML
      end
    end
  end
end
