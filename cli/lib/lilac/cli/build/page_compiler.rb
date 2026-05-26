# frozen_string_literal: true

require "fileutils"
require "pathname"
require "set"
require_relative "sfc"
require_relative "component_scripts_assembler"
require_relative "html_emitter"
require_relative "../live_reload"

module Lilac
  module CLI
    # Compiles one source `pages/*.html` file into a dist HTML, given the
    # build-level `BuildContext`. Handles:
    #
    #   - page-inline `<script type="text/ruby">` extraction
    #   - page-inline `<X data-component=...>` synthesis (Nokogiri pass)
    #   - data-use=X reference scanning
    #   - per-target / per-delivery dispatch (4 combos: full×inline,
    #     full×bundle, compiled×inline, compiled×bundle — including the
    #     chained .mrb boot module for compiled×bundle×page-inline)
    #
    # The outer `Builder.build` constructs the context once and invokes
    # `compile(page_path)` for each page; the compiler itself holds no
    # build-level state. See ADR-29 for the data-component / data-use
    # split and decisions §20.6 for the `Lilac.start` placement rationale.
    class PageCompiler
      # Matches `data-use="X"` / `data-use='X'` attribute values on any
      # element. We don't need to know which tag carries the attribute —
      # just collect the referenced component names so the build can
      # bundle their templates + scripts into the page.
      DATA_USE_PATTERN = %r{
        \bdata-use\s*=\s*(?:"([^"]+)"|'([^']+)')
      }x

      # Output of `build_injection`. The injection HTML is what gets
      # spliced before `</body>`; `page_local_mrb` is non-nil only in
      # the :compiled × :bundle case, where the per-page bytecode has
      # to be chained into the boot module instead of getting its own
      # `<script>` tag.
      Injection = Struct.new(:html, :page_local_mrb, keyword_init: true) do
        def empty?
          html.to_s.empty?
        end
      end

      def initialize(context)
        @ctx = context
        @scripts_assembler = ComponentScriptsAssembler.new(
          template_cache: context.template_cache,
          codegen: context.codegen
        )
      end

      def compile(page_path)
        html = File.read(page_path)

        # Inline `<script type="text/ruby">` blocks in the page itself are
        # surfaced to the injection step so they're not silently dropped on
        # the compiled target. The tags themselves stay in the dist HTML
        # for both targets:
        #   - target=full — the runtime parser evaluates them in place
        #     via `vm.evalScript`
        #   - target=compiled — the wasm has no parser so the tags are
        #     dead text (browser ignores `text/ruby`), but they remain
        #     so "view source" works, and features like the 7guis
        #     `source-display` mirror still find the page's Ruby. Size
        #     cost is marginal (a few KB, fully compressible) and the
        #     `.mrb` value prop (no parser in wasm) is unaffected
        extracted = SFC.extract_inline_ruby_scripts(html, path: page_path)
        page_inline_scripts = extracted[:scripts]

        # Page-inline `<X data-component="...">` elements are folded into
        # the same pipeline that handles `.lil` components: we register
        # an in-memory `SFC::Component` for each (snapshot of the
        # element's outer HTML), and empty out any `data-each` container
        # in the dist so the row template only lives in the synthetic
        # `<template data-template>` block — otherwise the live `<ul>`
        # would carry a phantom static row alongside the dynamically
        # rendered ones. Runtime resolves `refs.lilN` positionally, so
        # nothing else about the page markup needs to change.
        components, html, used_inline, synthesized_names = synthesize_page_inline_components(
          html, page_path: page_path
        )

        # R4: page-inline script classes that collide with `.lil`-derived
        # class names (project-global) are flagged before codegen. Done
        # AFTER synthesize_page_inline_components so synthesized in-memory
        # components (which carry no script) don't trigger false positives,
        # but BEFORE build_injection so the user sees a structured error
        # instead of a downstream Codegen / mrbc failure.
        @ctx.build_linter.check_class_name_collisions!(page_inline_scripts, components, synthesized_names, page_path)

        used = used_inline.dup
        # Page references to components via data-use="X" — the runtime
        # injects markup from the matching <template>...<div data-component="X">
        # definition that build_injection emits below. We only need to
        # record each X in `used` so its template + script land in the
        # injection bundle.
        html.scan(DATA_USE_PATTERN) do |dq, sq|
          name = dq || sq
          unless components.key?(name)
            raise Builder::Error,
                  "Unknown component referenced by data-use=#{name.inspect} in #{page_path} " \
                  "(no components/#{name}.lil and no page-inline data-component=#{name.inspect})"
          end
          used << name
        end

        html =
          if @ctx.delivery == :bundle
            inject_bundle_page(html, page_path, used, components,
                               page_inline_scripts: page_inline_scripts,
                               synthesized_names: synthesized_names)
          else
            injection = build_injection(used.uniq, components,
                                        page_inline_scripts: page_inline_scripts,
                                        synthesized_names: synthesized_names,
                                        page_path: page_path)
            injection.empty? ? html : HtmlEmitter.inject_before_body_close(html, injection.html)
          end

        File.write(output_path_for(page_path).tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, html)
      end

      private

      # Splice :bundle-delivery extras into a page: the
      # `<link rel="lilac-bundle">` reference, any page-local injection
      # (synthesized data-component templates + codegen for page-inline
      # scripts) and, for :compiled, the chained `<script type="module">`
      # boot stub.
      #
      # `.lil`-derived templates / scripts are NOT injected here — those
      # live in `dist/lilac.bundle.html` (already written by the builder).
      # Only the page-local slice does.
      def inject_bundle_page(html, page_path, used, components,
                             page_inline_scripts:, synthesized_names:)
        html = HtmlEmitter.inject_bundle_link(html, @ctx.bundle_assets.url) if @ctx.bundle_assets&.url

        extras = []
        page_local_mrb = nil

        page_local_names = used.uniq.select { |n| synthesized_names.include?(n) }
        unless page_local_names.empty? && page_inline_scripts.empty?
          injection = build_injection(
            page_local_names, components,
            page_inline_scripts: page_inline_scripts,
            synthesized_names: synthesized_names,
            page_path: page_path
          )
          extras << injection.html unless injection.empty?
          page_local_mrb = injection.page_local_mrb
        end

        if @ctx.target == :compiled
          chain = compiled_bundle_mrb_chain(page_local_mrb)
          extras << render_compiled_boot_module(chain, @ctx.package_dist_urls || []) unless chain.empty?
        end

        extras << LiveReload::SCRIPT if @ctx.live_reload
        extras.empty? ? html : HtmlEmitter.inject_before_body_close(html, extras.join("\n"))
      end

      # Decide the .mrb load order for a :compiled × :bundle page's boot
      # module. The bundle .mrb always loads first (component class
      # definitions, no `Lilac.start`). The tail is either the page-local
      # .mrb (which itself ends with `Lilac.start`) or the shared
      # `start-only.mrb` fallback so every page's chain terminates with
      # `Lilac.start`.
      def compiled_bundle_mrb_chain(page_local_mrb)
        return [] unless @ctx.bundle_assets

        chain = []
        chain << @ctx.bundle_assets.bundle_mrb if @ctx.bundle_assets.bundle_mrb
        if page_local_mrb
          chain << page_local_mrb
        elsif @ctx.bundle_assets.bundle_mrb && @ctx.bundle_assets.start_only_mrb
          chain << @ctx.bundle_assets.start_only_mrb
        end
        chain
      end

      # Lifts page-inline `data-component` elements into the same
      # codegen pipeline that `.lil` components go through. The element
      # stays where the user wrote it and the runtime mounts directly
      # via the `data-component` attribute. See full design notes in
      # ADR-29.
      def synthesize_page_inline_components(html, page_path:)
        components = @ctx.components

        # Quick string check — if there's no `data-component=` at all,
        # skip the round-trip and return the input verbatim.
        return [components, html, [], Set.new] unless html.match?(/\bdata-component\s*=/)

        require 'nokogiri' unless defined?(Nokogiri)
        doc = Nokogiri::HTML5.parse(html)

        # Collect data-component elements in document order. Each gets
        # a synthesized `SFC::Component` whose template body is the
        # element's OUTER HTML (full body, including any nested
        # data-component subtrees) — so the outer component's `data-each`
        # extraction picks up the nested row template verbatim, and the
        # nested component's own AST run sees its full body too.
        targets = []
        walk = lambda do |node|
          node.element_children.each do |child|
            targets << child if child['data-component']
            walk.call(child)
          end
        end
        walk.call(doc)

        return [components, html, [], Set.new] if targets.empty?

        # Capture the set of `.lil`-origin component names BEFORE we
        # start synthesising — `synthesized = components.dup` would
        # make a `synthesized.key?(name)` check tautological.
        lil_origin = components.keys.to_set
        synthesized = components.dup
        synthesized_names = Set.new
        used_inline = []
        seen_in_page = {} # name => line — for R2 duplicate detection
        targets.each do |elem|
          name = elem['data-component']

          # `.lil` and page-inline can't share a name — same-name
          # `data-component=` is a definition collision (ADR-29).
          if lil_origin.include?(name)
            lil_path = components[name].path
            raise Builder::Error, duplicate_definition_message(
              kind: :duplicate_with_lil,
              name: name,
              page_path: page_path,
              elem_line: elem.line,
              lil_path: lil_path
            )
          end

          # Same page can't declare the same `data-component=` twice
          # — same-name definition collision (ADR-29). Two
          # `<X data-component="row">` siblings would race on which
          # class body wins.
          if seen_in_page.key?(name)
            raise Builder::Error, duplicate_definition_message(
              kind: :duplicate_in_page,
              name: name,
              page_path: page_path,
              elem_line: elem.line,
              previous_line: seen_in_page[name]
            )
          end
          seen_in_page[name] = elem.line

          body_html = elem.to_html
          synthesized[name] = SFC::Component.new(
            path: page_path,
            templates: [SFC::Template.new(name: nil, body: body_html)],
            script: ''
          )
          synthesized_names << name
          # R3: record signature for cross-page drift detection.
          @ctx.build_linter.record_inline_signature(name, body_html, page_path)
          used_inline << name

          # Empty out `data-each` containers in the dist DOM. TemplateAST
          # already moves their bodies into synthetic `<template
          # data-template>` blocks for `bind_list` to clone at runtime;
          # leaving the static row in the live container would render it
          # as a phantom alongside the dynamically-instantiated ones.
          elem.css('[data-each]').each { |each_el| each_el.children.unlink }
        end

        [synthesized, doc.to_html, used_inline, synthesized_names]
      end

      # Build a structured definition-collision error message. ADR-29
      # requires each component name to be defined only once per page;
      # this method formats the user-facing message for each variant.
      def duplicate_definition_message(kind:, name:, page_path:, **detail)
        page_rel = page_path ? File.basename(page_path) : '(page)'
        case kind
        when :duplicate_with_lil
          lil_rel = detail[:lil_path] ? File.basename(detail[:lil_path]) : "components/#{name}.lil"
          "Duplicate component definition #{name.inspect}: " \
            "page-inline data-component on #{page_rel}:#{detail[:elem_line]} " \
            "conflicts with components/#{lil_rel}. " \
            'Each component name must be defined only once per page. ' \
            'Rename one of them.'
        when :duplicate_in_page
          "Duplicate component definition #{name.inspect}: " \
            "data-component on #{page_rel}:#{detail[:elem_line]} " \
            "is also declared at line #{detail[:previous_line]} of the same page. " \
            'Each component name must be defined only once per page.'
        else
          "Component definition collision: #{kind} (name=#{name.inspect}, page=#{page_rel})"
        end
      end

      def build_injection(used_names, components,
                          page_inline_scripts: [], synthesized_names: nil, page_path: nil)
        synthesized_names ||= Set.new

        default_templates = render_default_templates(used_names, components, synthesized_names)
        named_templates = render_named_templates(used_names, components)
        scripts = @scripts_assembler.assemble(
          used_names, components,
          synthesized_names: synthesized_names,
          page_inline_scripts: page_inline_scripts
        )
        bundle_scripts = compose_bundle_scripts(scripts, page_inline_scripts)
        script_block, page_local_mrb = render_script_block(bundle_scripts, page_path)

        # Live reload is dev-only; the `lilac build` command leaves it
        # off. When on, the snippet opens an SSE connection back to the
        # dev server and reloads the page on any "message" event.
        parts = [default_templates, named_templates, script_block]
        parts << LiveReload::SCRIPT if @ctx.live_reload
        Injection.new(html: parts.flatten.compact.join("\n"), page_local_mrb: page_local_mrb)
      end

      # Emit one `<template><div data-component="X">...</div></template>`
      # per used component, skipping synthesized in-memory components
      # (their markup is already written inline on the page). The
      # runtime registry consults these templates to fill empty
      # `data-use="X"` elements at mount time.
      def render_default_templates(used_names, components, synthesized_names)
        used_names.reject { |n| synthesized_names.include?(n) }.map do |name|
          parsed = @ctx.template_cache.fetch(name, components[name])
          HtmlEmitter.render_default_template(parsed[:default_html])
        end
      end

      def render_named_templates(used_names, components)
        used_names.flat_map do |name|
          parsed = @ctx.template_cache.fetch(name, components[name])
          parsed[:named].map { |nt| HtmlEmitter.render_named_template(nt.name, nt.html) }
        end
      end

      # Combine assembled component scripts with the page-inline ones
      # in a target-aware way. Page-inline `<script type="text/ruby">`
      # blocks join the bundle only on the compiled target — they're
      # emitted last so any `Lilac.start` written there runs after the
      # component class definitions. On :full they remain in the dist
      # HTML body and the runtime parser picks them up via
      # `vm.evalScript`, so duplicating them into the injected block
      # would re-execute them.
      #
      # `Lilac.start` placement differs by target (decisions §20.6
      # corrected: the compiled wasm has no parser, so post-load
      # `vm.eval("Lilac.start")` is not available):
      # - target=:compiled — append `Lilac.start` to the bundle so it
      #   executes as part of `loadBytecode`.
      # - target=:full — do nothing here; the Pattern A boot helper
      #   (scaffold `boot.js`, lilac-full's CDN `boot`, …) runs
      #   `vm.eval("Lilac.start")` at the tail of its eval loop.
      def compose_bundle_scripts(scripts, page_inline_scripts)
        return scripts unless @ctx.target == :compiled

        user_scripts = scripts + page_inline_scripts.reject { |s| s.strip.empty? }
        user_scripts.empty? ? [] : user_scripts + ['Lilac.start']
      end

      # Returns `[script_block_html, page_local_mrb]`. Either element
      # may be nil:
      #   - no scripts at all → both nil
      #   - :full → script_block is `<script type="text/ruby">…</script>`, mrb is nil
      #   - :compiled × :inline → script_block is the inline boot
      #     module that loads + boots the .mrb; mrb is nil
      #   - :compiled × :bundle → script_block is nil (caller chains
      #     the page-local mrb into the shared bundle boot module);
      #     page_local_mrb is the .mrb filename to chain.
      def render_script_block(bundle_scripts, page_path)
        return [nil, nil] if bundle_scripts.empty?

        ruby_source = bundle_scripts.join("\n\n")
        return [HtmlEmitter.render_script(ruby_source), nil] unless @ctx.target == :compiled

        # :compiled — compile the aggregated Ruby to `.mrb` bytecode.
        # The `data-lilac-bootstrap` attribute on the emitted module
        # script marks the tag so a future asset-pipeline pass can
        # rewrite the URLs.
        label = page_path ? "page #{File.basename(page_path)}" : 'page bundle'
        mrb_file = @ctx.bytecode_builder.build(ruby_source, source_label: label)

        if @ctx.delivery == :bundle
          # The page-local .mrb is chained into the same boot module
          # as the bundle .mrb by the caller — emit no <script> here.
          [nil, mrb_file]
        else
          [render_compiled_boot_module(mrb_file, @ctx.package_dist_urls || []), nil]
        end
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
      # builder appends `Lilac.start` to the bundle in `bundle_scripts`
      # so it runs as part of `loadBytecode` (decisions §20.6 caveat).
      def render_compiled_boot_module(mrb_filenames, package_urls = [])
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
          if @ctx.delivery == :bundle
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

      def output_path_for(page_path)
        rel = Pathname.new(page_path).relative_path_from(Pathname.new(@ctx.pages_dir))
        File.join(@ctx.output_dir, rel.to_s)
      end
    end
  end
end
