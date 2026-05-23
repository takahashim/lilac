# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require_relative 'sfc'
require_relative 'template_ast'
require_relative 'codegen'
require_relative 'component_name'
require_relative 'cross_ref_linter'
require_relative 'bytecode_builder'
require_relative 'form_extension'

module Lilac
  module CLI
    # Reads `.lil` components and `.html` pages, then emits static HTML.
    #
    # Page authors mark component insertion points with
    #   <lilac-component name="counter"></lilac-component>
    # which is replaced by the component's default-template markup.
    # Named sub-templates and Ruby class scripts from all components used
    # on the page are injected once each before `</body>`.
    #
    # Component file naming: `components/<data-component-name>.lil`. The file's
    # basename is taken verbatim as the component name, so
    # `admin--user-card.lil` matches `<lilac-component name="admin--user-card">`
    # and (via the runtime autoregister) the `Admin::UserCard` class.
    class Builder
      class Error < StandardError; end

      # A template ready to be injected as `<template data-template="X">`
      # into the page. Both user-defined named templates (from
      # `<template data-template="...">` in `.lil` source) and synthetic
      # data-each iteration bodies extracted by TemplateAST end up as
      # this single shape — the page-injection logic doesn't need to
      # know which side they came from.
      RenderedTemplate = Struct.new(:name, :html, keyword_init: true)

      # Accepted forms (all match the same component name in capture 1):
      #
      #   <lilac-component name="counter"></lilac-component>
      #   <lilac-component name='counter'></lilac-component>
      #   <lilac-component name="counter" />
      #   <lilac-component name="counter"/>
      #
      # Additional attributes beyond `name` are intentionally NOT supported:
      # the placeholder is replaced wholesale at build time, so any extra
      # attribute would silently disappear rather than reach the component.
      COMPONENT_PLACEHOLDER = %r{
        <lilac-component
        \s+name=(?:"([^"]+)"|'([^']+)')
        \s*
        (?:/>|>\s*</lilac-component>)
      }x

      # Filenames that must not land in the build output even when they
      # exist under `public/`. Add to this list as new conventions are
      # encountered (e.g. `.DS_Store`, `Thumbs.db`).
      EXCLUDED_BASENAMES = %w[.gitkeep].freeze

      # Target-specific public/ subdirectories that should NOT be mirrored
      # into dist/ for the inactive target. Both runtime variants live
      # under their own namespace in `public/vendor/` so a project that
      # ships both (e.g. dev=full, prod=compiled) can keep them side by
      # side and let the CLI prune the inactive one at build time.
      #
      # Paths are relative to `public_dir`, POSIX style. The match is on
      # path prefix + boundary, so `vendor/lilac-full` matches
      # `vendor/lilac-full/lilac-full.wasm` but not `vendor/lilac-full-x`.
      EXCLUDED_DIRS_FOR_TARGET = {
        full: %w[vendor/lilac-compiled].freeze,
        compiled: %w[vendor/lilac-full].freeze
      }.freeze

      # Client snippet injected into every dev-server page. Subscribes
      # to the dev server's SSE channel and handles two event types:
      #
      #   - default `message` event → successful rebuild, reload the page
      #     (any in-page error overlay is implicitly discarded by the
      #     reload, no explicit cleanup needed)
      #   - `error` event → build failed; render an in-page overlay with
      #     the error type + message so the dev sees the failure without
      #     switching to the terminal
      #
      # The overlay is self-contained: inline CSS in a namespaced id
      # (`__lilac_err_overlay`), no dependency on user styles.
      LIVE_RELOAD_SCRIPT = <<~HTML
        <script>
          // lilac dev: live reload + error overlay via SSE
          (function () {
            const ES_URL = "/__lilac/livereload";
            const OVERLAY_ID = "__lilac_err_overlay";

            function renderOverlay(payload) {
              document.getElementById(OVERLAY_ID)?.remove();
              const root = document.createElement("div");
              root.id = OVERLAY_ID;
              root.setAttribute("style", [
                "position:fixed", "inset:0", "z-index:2147483647",
                "background:rgba(0,0,0,0.78)", "color:#fff",
                "font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace",
                "padding:32px", "overflow:auto",
              ].join(";"));

              const panel = document.createElement("div");
              panel.setAttribute("style", [
                "max-width:880px", "margin:0 auto",
                "background:#1f1f23", "border:1px solid #ff5b6c",
                "border-radius:8px", "padding:20px 24px",
                "box-shadow:0 12px 40px rgba(0,0,0,0.45)",
              ].join(";"));

              const head = document.createElement("div");
              head.setAttribute("style", "display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px");
              const title = document.createElement("strong");
              title.textContent = "lilac dev: build failed";
              title.setAttribute("style", "color:#ff5b6c;font-size:15px");
              const close = document.createElement("button");
              close.type = "button";
              close.textContent = "×";
              close.setAttribute("aria-label", "Dismiss");
              close.setAttribute("style", "background:transparent;border:0;color:#fff;font-size:22px;cursor:pointer;line-height:1");
              close.addEventListener("click", () => root.remove());
              head.appendChild(title);
              head.appendChild(close);
              panel.appendChild(head);

              if (payload && payload.type) {
                const t = document.createElement("div");
                t.textContent = payload.type;
                t.setAttribute("style", "color:#9aa0a6;font-size:12px;margin-bottom:8px");
                panel.appendChild(t);
              }

              const msg = document.createElement("pre");
              msg.textContent = (payload && payload.message) || "(no message)";
              msg.setAttribute("style", "white-space:pre-wrap;word-break:break-word;margin:0;color:#f5f5f5");
              panel.appendChild(msg);

              const hint = document.createElement("div");
              hint.textContent = "Save the file to retry — this overlay will close automatically on a successful rebuild.";
              hint.setAttribute("style", "color:#9aa0a6;font-size:12px;margin-top:14px");
              panel.appendChild(hint);

              root.appendChild(panel);
              document.body.appendChild(root);
            }

            const es = new EventSource(ES_URL);
            es.addEventListener("message", () => location.reload());
            es.addEventListener("error", (ev) => {
              // EventSource fires "error" on transport failure too — those
              // have no `data` field. Distinguish from server-sent error
              // events by presence of `ev.data`.
              if (!ev.data) return;
              try {
                renderOverlay(JSON.parse(ev.data));
              } catch (_e) {
                renderOverlay({ type: "(parse failure)", message: ev.data });
              }
            });
          })();
        </script>
      HTML

      def initialize(components_dir:, pages_dir:, output_dir:, public_dir: nil,
                     live_reload: false, codegen: :auto,
                     target: :full, mrbc_path: nil,
                     lilac_compiled_path: nil, mruby_wasm_js_path: nil,
                     plugins: [],
                     project_root: Dir.pwd,
                     disable_gem_discovery: false)
        @components_dir = components_dir
        @pages_dir = pages_dir
        @output_dir = output_dir
        # public_dir is optional. When nil or absent on disk, the
        # mirroring step is skipped — projects that don't need static
        # passthrough (no vendor bundle, no images) work fine without
        # creating the directory.
        @public_dir = public_dir
        @live_reload = live_reload
        # `:auto` (default) — emit Lilac::Bindings::<Class>#bind_template_hook
        # pre-compiled bindings; `:off` — skip codegen and let the
        # runtime scanner interpret data-* directives at mount time
        # (parity-test mode, validates the runtime path against the
        # same .lil source).
        @codegen = codegen
        # `:full` — dist HTML loads inline Ruby via lilac-full wasm
        # (vm.evalScript). `:compiled` — Ruby is pre-compiled to
        # `.mrb` bytecode via `mrbc` and loaded by lilac-compiled wasm
        # (vm.loadBytecode). The compiled target shaves ~32% off the brotli
        # bundle but requires `mrbc` available at build time. See
        # `BytecodeBuilder` for path discovery.
        @target = target
        @mrbc_path = mrbc_path
        # Discovery hints for the compiled runtime — wasm + boot helper
        # + JS bridge. Used by `auto_vendor_compiled_runtime!` so the
        # built dist is fully self-contained and no manual cp into
        # `public/vendor/lilac-compiled/` is required.
        @lilac_compiled_path = lilac_compiled_path
        @mruby_wasm_js_path  = mruby_wasm_js_path
        # Pre-compiled plug-in `.mrb` paths (absolute). For `:compiled`
        # builds, each gets copied into `dist/plugins/` and pre-loaded by
        # the generated boot script before user bytecode. Ignored for
        # `:full` builds (no boot script to inject into). See §24.
        @plugins             = Array(plugins).map { |p| File.expand_path(p) }
        @project_root        = project_root
        # Mirrors `CompiledRuntimeResolver` / `BytecodeBuilder`'s
        # `disable_gem_discovery:` — tests pass `true` so the gem-bundled
        # wasm doesn't satisfy lookups they're trying to isolate. Plumbed
        # through to both resolvers below.
        @disable_gem_discovery = disable_gem_discovery
      end

      def build
        components = load_components
        pages = Dir.glob(File.join(@pages_dir, '**', '*.html'))
        raise Error, "No pages found under #{@pages_dir.inspect}" if pages.empty?

        public_files = mirror_public_files

        # Resolve and stage plug-in `.mrb` files once for the build —
        # the URLs are stable across pages so each page's boot module
        # can reference the same set.
        @plugin_dist_urls = copy_plugins!
        # `:full` target doesn't generate its own boot module (user's
        # scaffold-provided `<script type="module">` owns boot), so we
        # surface the plug-in list as a `lilac.plugins.json` manifest the
        # user-side boot can fetch. `:compiled` doesn't need this — the
        # generated `data-lilac-bootstrap` module inlines the URLs.
        write_plugins_manifest!(@plugin_dist_urls) if @target == :full

        # Caches per component name to avoid re-parsing template bodies
        # when the same component appears on multiple pages.
        @template_ast_cache = {}

        # Records `{ name => [ [content_hash, page_path], ... ] }` for
        # every page-inline `data-component` element across pages. The
        # post-loop pass warns when the same name appears with
        # different shapes (proposal §A.R3) — page-inline components
        # are page-local, so divergent shapes don't break runtime, but
        # users typically intend "same name = same UI" and the warning
        # surfaces unintentional drift.
        @page_inline_signatures = Hash.new { |h, k| h[k] = [] }

        pages.each do |page_path|
          build_page(page_path, components)
        end

        warn_cross_page_signature_drift!

        # `:compiled` target needs the runtime (wasm + bridge + boot
        # helper) sitting under `dist/vendor/lilac-compiled/`. We emit
        # it from the CLI directly so users don't have to vendor the
        # npm package by hand. Skipped when no `.mrb` was actually
        # produced — pages without any Ruby script don't reference the
        # bootstrap module.
        auto_vendor_compiled_runtime! if @target == :compiled && Dir.glob(File.join(@output_dir, '*.mrb')).any?

        { pages: pages.length, components: components.length, public_files: public_files }
      end

      private

      # Returns { default_html:, default_directives:, named: [RenderedTemplate, ...] }
      # for a component, caching the result.
      #
      # `data-each` iteration bodies extracted by TemplateAST are folded
      # into `named` as synthetic templates using `ComponentName#each_template_name`
      # so they ride the same `<template data-template>` injection path
      # as user-defined named templates and the runtime can resolve them
      # via `bind_list ..., template: "lil-each-<component>-<ref>"`.
      def template_ast_for(name, component)
        @template_ast_cache[name] ||= begin
          component_name = ComponentName.new(name)

          default_results = component.default_templates.map do |t|
            TemplateAST.new(t.body, source_path: component.path).parse
          end

          named = component.named_templates.map do |t|
            result = TemplateAST.new(t.body, source_path: component.path).parse
            RenderedTemplate.new(name: t.name, html: result.html)
          end

          synthetic = default_results.flat_map(&:synthetic_templates).map do |st|
            RenderedTemplate.new(
              name: component_name.each_template_name(st.ref_id),
              html: st.html
            )
          end

          {
            default_html: default_results.map(&:html).join.strip,
            default_directives: default_results.flat_map(&:directives),
            default_refs_map: default_results.map(&:refs_map).reduce({}, :merge),
            named: named + synthetic,
            source_path: component.path
          }
        end
      end

      # Mirror `public/**/*` → `output_dir/`. Preserves the relative
      # directory structure (e.g. `public/vendor/x.js` →
      # `output_dir/vendor/x.js`). Returns the number of files copied.
      #
      # `.gitkeep` is filtered so an empty placeholder file doesn't
      # land in the build output. Other dot-prefixed files (e.g.
      # `.well-known/`) are copied so users can publish standard web
      # conventions.
      def mirror_public_files
        return 0 unless @public_dir && File.directory?(@public_dir)

        excluded_dirs = EXCLUDED_DIRS_FOR_TARGET.fetch(@target, [])
        copied = 0
        Dir.glob(File.join(@public_dir, '**', '*'), File::FNM_DOTMATCH).each do |source|
          # File.file? already filters out the `.` / `..` directory
          # entries that FNM_DOTMATCH surfaces, so no extra guard needed.
          next unless File.file?(source)
          next if EXCLUDED_BASENAMES.include?(File.basename(source))

          rel = Pathname.new(source).relative_path_from(Pathname.new(@public_dir)).to_s
          next if excluded_dirs.any? { |prefix| rel == prefix || rel.start_with?("#{prefix}/") }

          dest = File.join(@output_dir, rel)
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(source, dest)
          copied += 1
        end
        copied
      end

      def load_components
        Dir.glob(File.join(@components_dir, '**', '*.lil')).to_h do |path|
          [File.basename(path, '.lil'), SFC.parse_file(path)]
        end
      end

      def build_page(page_path, components)
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
          html, components: components, page_path: page_path
        )

        # R4: page-inline script classes that collide with `.lil`-derived
        # class names (project-global) are flagged before codegen. Done
        # AFTER synthesize_page_inline_components so synthesized in-memory
        # components (which carry no script) don't trigger false positives,
        # but BEFORE build_injection so the user sees a structured error
        # instead of a downstream Codegen / mrbc failure.
        check_class_name_collisions!(page_inline_scripts, components, synthesized_names, page_path)

        used = used_inline.dup
        html = html.gsub(COMPONENT_PLACEHOLDER) do
          # Capture 1 = double-quoted name; capture 2 = single-quoted name.
          name = Regexp.last_match(1) || Regexp.last_match(2)
          comp = components[name] || raise(Error, "Unknown component: #{name.inspect} (referenced in #{page_path})")
          used << name
          default_markup(name, comp)
        end

        injection = build_injection(used.uniq, components,
                                    page_inline_scripts: page_inline_scripts,
                                    synthesized_names: synthesized_names,
                                    page_path: page_path)
        html = inject_before_body_close(html, injection) unless injection.empty?

        File.write(output_path_for(page_path).tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, html)
      end

      # Lifts page-inline `data-component` elements into the same
      # codegen pipeline that `.lil` components go through, WITHOUT
      # rewriting the page HTML to a `<lilac-component>` placeholder —
      # the element stays where the user wrote it and the runtime mounts
      # directly via the `data-component` attribute.
      #
      # For every element carrying `data-component=` (top-level AND
      # nested — e.g. a `data-each` row component inside an outer page
      # component):
      #
      #   * Registers an in-memory `SFC::Component` keyed by component
      #     name. The template body is the element's OUTER HTML so the
      #     subsequent TemplateAST run sees the full subtree (and the
      #     outer component's `data-each` extraction picks up the row
      #     template verbatim). The `script:` slot is left empty — the
      #     real class definitions live in page-inline `<script
      #     type="text/ruby">` blocks which `extract_inline_ruby_scripts`
      #     already pulled out and which `build_injection` will weld
      #     into the bundle.
      #   * Records the name in both `used_inline` (so `build_injection`
      #     runs codegen for it — every synthesized component, nested
      #     or not, needs its own `Lilac::Bindings::<Class>#bind_template_hook`)
      #     and `synthesized_names` (so the linter knows to feed those
      #     components the page-level inline-script text instead of the
      #     empty per-component `script:` slot).
      #
      # Then strips children out of every `data-each` container that
      # lives under a synthesized component: TemplateAST will turn the
      # row body into a synthetic `<template data-template>` block for
      # `bind_list` to clone at runtime, and leaving the static row in
      # the live container would render a phantom alongside the
      # dynamically-instantiated ones.
      #
      # Pages with no `data-component=` substring skip Nokogiri entirely
      # so their bytes are preserved verbatim (matters for hand-written
      # outer HTML with `<html>` / `<head>` / `<body>` boundaries that
      # the Nokogiri round-trip would normalize).
      #
      # Returns `[components_with_synthesized, possibly_rewritten_html,
      # used_inline, synthesized_names]`.
      def synthesize_page_inline_components(html, components:, page_path:)
        # Quick string check — if there's no `data-component=` at all,
        # skip the round-trip and return the input verbatim.
        return [components, html, [], Set.new] unless html.match?(/\bdata-component\s*=/)

        require 'nokogiri' unless defined?(Nokogiri)
        unless defined?(Set)
        end
        doc = Nokogiri::HTML5.parse(html)

        # Collect data-component elements in document order. Each gets
        # a synthesized `SFC::Component` whose template body is the
        # element's OUTER HTML (full body, including any nested
        # data-component subtrees) — that way the outer component's
        # `data-each` extraction picks up the nested row template
        # verbatim, and the nested component's own AST run sees its
        # full body too.
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

          # R1: `.lil` and page-inline can't share a name. The .lil
          # version would be silently shadowed otherwise — see
          # proposal §A.R1.
          if lil_origin.include?(name)
            lil_path = components[name].path
            raise Error, build_scope_error_message(
              kind: :lil_vs_page_inline,
              name: name,
              page_path: page_path,
              elem_line: elem.line,
              lil_path: lil_path
            )
          end

          # R2: same page can't declare the same page-inline component
          # twice. Two `<X data-component="row">` siblings would race
          # on which class body wins. See proposal §A.R2.
          if seen_in_page.key?(name)
            raise Error, build_scope_error_message(
              kind: :same_page_duplicate,
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
          @page_inline_signatures[name] << [signature_for(body_html), page_path] if @page_inline_signatures
          used_inline << name

          # Empty out `data-each` containers in the dist DOM. TemplateAST
          # already moves their bodies into synthetic `<template
          # data-template>` blocks for `bind_list` to clone at runtime;
          # leaving the static row in the live container would render it
          # as a phantom alongside the dynamically-instantiated ones.
          # Restricted to descendants of synthesized data-component
          # elements so unrelated `data-each` elsewhere on the page
          # (none in practice today, but the rule is conservative)
          # stays untouched.
          elem.css('[data-each]').each { |each_el| each_el.children.unlink }
        end

        [synthesized, doc.to_html, used_inline, synthesized_names]
      end

      # R4: any class declared at the top level of a page-inline script
      # whose name collides with a `.lil`-derived class name aborts the
      # build. Page-inline scripts and `.lil` scripts both land in the
      # same Ruby namespace at runtime, so a colliding name would
      # silently reopen the .lil class — surprise that we'd rather
      # catch at build time.
      def check_class_name_collisions!(page_inline_scripts, components, synthesized_names, page_path)
        return if page_inline_scripts.empty?

        # `.lil` class names (skip synthesized in-memory entries — those
        # are the page-inline data-component snapshots, not real .lil files).
        lil_class_names = {} # ruby_class_name => kebab (original file)
        components.each_key do |name|
          next if synthesized_names.include?(name)

          ruby_name = ComponentName.new(name).ruby_class
          lil_class_names[ruby_name] = name
        end
        return if lil_class_names.empty?

        page_inline_scripts.each do |script|
          ScriptAnalyzer.extract_top_level_class_names(script).each do |declared|
            next unless lil_class_names.key?(declared)

            raise Error, build_scope_error_message(
              kind: :class_name_vs_lil,
              name: declared,
              page_path: page_path,
              lil_basename: "#{lil_class_names[declared]}.lil"
            )
          end
        end
      end

      # Stable hash of a page-inline component element body (outer HTML)
      # for cross-page drift detection (proposal §A.R3). Whitespace
      # normalised so cosmetic indentation differences across pages don't
      # spuriously fire the warning.
      def signature_for(body_html)
        require 'digest' unless defined?(Digest)
        Digest::SHA1.hexdigest(body_html.gsub(/\s+/, ' ').strip)
      end

      # R3: after every page is built, scan recorded signatures for the
      # same name appearing with different content_hashes across pages.
      # Output a single warning grouping divergent pages so the user can
      # decide whether to rename one of them or align the shapes.
      def warn_cross_page_signature_drift!
        return unless @page_inline_signatures

        @page_inline_signatures.each do |name, entries|
          unique_sigs = entries.map { |sig, _| sig }.uniq
          next if unique_sigs.size <= 1

          pages_str = entries.uniq { |sig, _| sig }
                             .map { |_sig, page| File.basename(page) }
                             .join(', ')
          warn(
            "[lilac] page-inline component #{name.inspect} appears with " \
            "different shapes across pages (#{pages_str}). " \
            'Page-inline names are page-local so this is allowed, but ' \
            'is likely unintentional drift — consider renaming or moving ' \
            "the component to components/#{name}.lil to share one shape."
          )
        end
      end

      def default_markup(name, component)
        template_ast_for(name, component)[:default_html]
      end

      # Build a structured scope-violation error message. See proposals.md
      # §A.R1〜R4 — the scope rule for `.lil` (project-global) vs page-
      # inline `data-component` (page-local) vs page-inline script
      # (page-local execution).
      def build_scope_error_message(kind:, name:, page_path:, **detail)
        page_rel = page_path ? File.basename(page_path) : '(page)'
        case kind
        when :lil_vs_page_inline
          lil_rel = detail[:lil_path] ? File.basename(detail[:lil_path]) : "components/#{name}.lil"
          "data-component=#{name.inspect} on #{page_rel}:#{detail[:elem_line]} " \
            "collides with components/#{lil_rel} (project-global). " \
            'Page-inline components are page-local, so the silent shadowing ' \
            'would surprise. Rename one of them.'
        when :same_page_duplicate
          "data-component=#{name.inspect} on #{page_rel}:#{detail[:elem_line]} " \
            "is declared twice in the same page (first at line #{detail[:previous_line]}). " \
            'Page-inline component names must be unique within a page.'
        when :class_name_vs_lil
          "page-inline class #{name} in #{page_rel} collides with the class " \
            "derived from components/#{detail[:lil_basename]}. " \
            'Rename either the page-inline class or the .lil file.'
        else
          "scope violation: #{kind} (name=#{name.inspect}, page=#{page_rel})"
        end
      end

      def build_injection(used_names, components,
                          page_inline_scripts: [], synthesized_names: nil, page_path: nil)
        synthesized_names ||= Set.new
        # The page-level inline Ruby is the canonical class definitions
        # for every synthesized component. Pass it as the lint context so
        # the cross-ref linter can resolve `@signal` / `def method` etc.
        # The user_script slot on each synthesized component stays empty
        # so the bundle doesn't end up with the inline scripts twice.
        synth_lint_script = page_inline_scripts.join("\n\n")

        named_templates = used_names.flat_map do |name|
          parsed = template_ast_for(name, components[name])
          parsed[:named].map { |nt| render_named_template(nt.name, nt.html) }
        end

        scripts = used_names.map do |name|
          comp = components[name]
          parsed = template_ast_for(name, comp)
          user_script = comp.script.strip
          # For synthesized in-memory components the script slot is
          # empty (the actual class definitions live in the page's
          # inline `<script type="text/ruby">` blocks). Feed those into
          # the linter so `@count` / method-name lookups can resolve.
          lint_script = synthesized_names.include?(name) ? synth_lint_script : user_script
          # Cross-reference lint runs before codegen so any warnings
          # appear ahead of generated source in build output, matching
          # the user's mental order ("first the diagnostics, then the
          # result"). Non-fatal — warnings go to stderr and the build
          # carries on.
          lint_result = CrossRefLinter.lint(
            script_text: lint_script,
            directives: parsed[:default_directives],
            refs_map: parsed[:default_refs_map],
            component_name: ComponentName.new(name).ruby_class,
            file: parsed[:source_path] ? File.basename(parsed[:source_path]) : '(template)'
          )
          if lint_result.errors?
            raise Error, "build failed: #{lint_result.errors} lint error(s) in template; see warnings above."
          end

          generated =
            if @codegen == :off
              # Runtime scanner mode: emit no bind_template_hook,
              # leaving the runtime to interpret data-* at mount.
              ''
            else
              # Both targets rely on Component#bind_template_hook to
              # look up `Lilac::Bindings::<Class>` by name. The explicit
              # `<Class>.include(...)` line is dropped — it would
              # either NameError (codegen runs before the class def)
              # or run too late (after the user's `Lilac.start`, which
              # already triggered bind_template_hook on mount).
              Codegen.generate(
                component_name: name,
                directives: parsed[:default_directives],
                source_path: parsed[:source_path],
                emit_include: false
              ).strip
            end
          # Generated FIRST so that `Lilac::Bindings::<Class>` is
          # defined before the user script's `Lilac.start` mounts
          # components and calls `bind_template_hook`. The component
          # base's `lookup_codegen_bindings` resolves and includes the
          # module on demand at that point.
          parts = [generated, user_script]
          parts.reject(&:empty?).join("\n\n")
        end.reject(&:empty?)

        # Page-inline `<script type="text/ruby">` blocks join the bundle
        # only on the compiled target — they're emitted last so any
        # `Lilac.start` written there runs after the component class
        # definitions. On :full they remain in the dist HTML body and
        # the runtime parser picks them up via `vm.evalScript`, so
        # duplicating them into the injected block would re-execute
        # them.
        #
        # `Lilac.start` placement differs by target (decisions §20.6
        # corrected: the compiled wasm has no parser, so post-load
        # `vm.eval("Lilac.start")` is not available):
        # - target=:compiled — append `Lilac.start` to the bundle so it
        #   executes as part of `loadBytecode`. The inline boot module
        #   does NOT call `vm.eval` (would require mruby-compiler /
        #   mruby-eval, both excluded from the compiled wasm)
        # - target=:full — do nothing here; the Pattern A boot helper
        #   (scaffold `boot.js`, `@takahashim/lilac-full#boot`, …) runs
        #   `vm.eval("Lilac.start")` at the tail of its eval loop
        bundle_scripts =
          if @target == :compiled
            user_scripts = scripts + page_inline_scripts.reject { |s| s.strip.empty? }
            user_scripts.empty? ? [] : user_scripts + ['Lilac.start']
          else
            scripts
          end
        ruby_source = bundle_scripts.join("\n\n")
        script_block =
          if bundle_scripts.empty?
            nil
          elsif @target == :compiled
            # Compile the aggregated Ruby to `.mrb` bytecode and emit a
            # module script that fetches the bytecode + boots the
            # lilac-compiled wasm. The `data-lilac-bootstrap` attribute
            # marks the tag so a future asset-pipeline pass can rewrite
            # the URLs.
            label = page_path ? "page #{File.basename(page_path)}" : 'page bundle'
            mrb_file = bytecode_builder.build(ruby_source, source_label: label)
            render_compiled_boot_module(mrb_file, @plugin_dist_urls || [])
          else
            render_script(ruby_source)
          end

        # Live reload is dev-only; the `lilac build` command leaves it
        # off. When on, the snippet opens an SSE connection back to the
        # dev server and reloads the page on any "message" event.
        parts = [named_templates, script_block]
        parts << LIVE_RELOAD_SCRIPT if @live_reload
        parts.flatten.compact.join("\n")
      end

      # Lazily instantiated so `:full` builds incur no mrbc resolution
      # cost (`BytecodeBuilder.new` itself is cheap, but keeping the
      # creation lazy keeps the `:full` happy path obviously side-effect-free).
      def bytecode_builder
        @bytecode_builder ||= BytecodeBuilder.new(
          mrbc_path: @mrbc_path,
          output_dir: @output_dir,
          disable_gem_discovery: @disable_gem_discovery
        )
      end

      # Lazily resolves the lilac-compiled runtime (wasm + bridge + boot
      # helper). Constructed only when target=:compiled actually emits a
      # `.mrb`, mirroring `bytecode_builder`'s "no cost on the happy
      # :full path" pattern.
      def compiled_runtime_resolver
        @compiled_runtime_resolver ||= CompiledRuntimeResolver.new(
          lilac_compiled_path: @lilac_compiled_path,
          mruby_wasm_js_path: @mruby_wasm_js_path,
          project_root: @project_root,
          disable_gem_discovery: @disable_gem_discovery
        )
      end

      # Emits `dist/vendor/lilac-compiled/{lilac.wasm,mruby-wasm-js/...}`
      # from the resolved runtime sources. The boot module itself is
      # rendered inline in the page HTML (see render_compiled_boot_module),
      # so we don't need to vendor `index.js`: the page imports the
      # bridge directly and calls `loadBytecode` itself.
      #
      # Raises `CompiledRuntimeResolver::Error` if a source is missing,
      # with an actionable message — the caller (the build command) lets
      # it propagate.
      def auto_vendor_compiled_runtime!
        vendor_dir = File.join(@output_dir, 'vendor', 'lilac-compiled')
        bridge_out = File.join(vendor_dir, 'mruby-wasm-js')
        FileUtils.mkdir_p(bridge_out)

        wasm_src = compiled_runtime_resolver.resolve_wasm!
        FileUtils.cp(wasm_src, File.join(vendor_dir, 'lilac.wasm'))

        bridge_src = compiled_runtime_resolver.resolve_bridge!
        Dir.glob(File.join(bridge_src, '*')).each do |entry|
          next if File.directory?(entry)

          FileUtils.cp(entry, File.join(bridge_out, File.basename(entry)))
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
      def render_compiled_boot_module(mrb_filename, plugin_urls = [])
        # Plug-in `.mrb` bundles load BEFORE the user bytecode so any
        # `register_directive` calls take effect by the time component
        # mount runs `scan_extensions`. Mirrors the production
        # `boot({ plugins })` ordering in `npm/lilac-compiled/index.js`.
        # The heredoc below uses 2-space indent (squiggly heredoc strips
        # the common leading whitespace). Plug-in load lines slot in
        # before `const bytecode = ...` at the same depth.
        plugin_loads = plugin_urls.map do |url|
          "vm.loadBytecode(new Uint8Array(await (await fetch(#{url.inspect})).arrayBuffer()));"
        end.join("\n  ")
        plugin_block = plugin_loads.empty? ? '' : "#{plugin_loads}\n  "
        <<~HTML.strip
          <script type="module" data-lilac-bootstrap>
            import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js";
            const vm = await createVM({ wasm: "./vendor/lilac-compiled/lilac.wasm" });
            #{plugin_block}const bytecode = new Uint8Array(
              await (await fetch("./#{mrb_filename}")).arrayBuffer()
            );
            vm.loadBytecode(bytecode);
          </script>
        HTML
      end

      # Stage plug-in `.mrb` files under `dist/plugins/` and return the
      # page-relative URLs the boot script should `fetch`. Two input
      # channels merge here (decisions §25):
      #
      #   1. **Bundler auto-discovery** — `PluginDiscovery.run` finds gems
      #      whose gemspec declares `metadata["lilac_plugin"] = "true"`.
      #      Each gem's `mrblib/*.rb` is compiled locally to `.mrb` so the
      #      mruby version matches the vendored core wasm.
      #   2. **Explicit `c.plugins = [...paths]`** — pre-compiled `.mrb`
      #      files. Useful for advanced overrides (custom plug-in not in
      #      a gem, vendored fork, etc.).
      #
      # Both `:full` and `:compiled` targets benefit from plug-ins —
      # `:compiled` injects loadBytecode into the generated boot module
      # directly, `:full` writes a `lilac.plugins.json` manifest that the
      # user's hand-rolled (scaffold) boot script reads to loadBytecode
      # plug-ins ahead of `evalScript`. See decisions §25.
      def copy_plugins!
        return [] if @plugins.empty? && discovered_plugins.empty?

        dest_dir = File.join(@output_dir, 'plugins')
        FileUtils.mkdir_p(dest_dir)

        urls = []
        # Auto-discovered gem-based plug-ins first. Compile each gem's
        # mrblib source set to a single `.mrb` named after the gem so the
        # filename collisions with explicit override paths are easy to
        # spot.
        discovered_plugins.each do |discovered|
          bytes = compile_plugin_source(discovered.mrblib_files, source_label: discovered.name)
          filename = "#{discovered.name}.mrb"
          File.binwrite(File.join(dest_dir, filename), bytes)
          urls << "./plugins/#{filename}"
        end
        # Explicit override paths next — already-compiled `.mrb` files
        # the user pointed at directly via `c.plugins`.
        @plugins.each do |src|
          raise Error, "Plug-in `.mrb` not found: #{src}" unless File.file?(src)

          basename = File.basename(src)
          FileUtils.cp(src, File.join(dest_dir, basename))
          urls << "./plugins/#{basename}"
        end
        urls.uniq
      end

      # Cached `PluginDiscovery` result so multi-page builds discover
      # once. Empty list outside a Bundler context.
      def discovered_plugins
        @discovered_plugins ||= PluginDiscovery.run
      end

      # Compile concatenated mrblib source to bytecode via the existing
      # `BytecodeBuilder` backend chain (binary mrbc → wasm-driven mrbc
      # → $PATH). Mirrors `lilac plugin-build`'s aggregation rule:
      # alphabetical concat separated by newlines.
      def compile_plugin_source(mrblib_files, source_label:)
        source = mrblib_files.map { |f| File.read(f) }.join("\n")
        bytecode_builder.compile_to_bytes(source, source_label: "plug-in #{source_label}")
      end

      # Write `dist/lilac.plugins.json` so a scaffold-style boot script
      # can fetch the manifest and `loadBytecode` each entry before
      # evaluating `<script type="text/ruby">` blocks. Format:
      #
      #   { "plugins": ["./plugins/lilac-plugin-extras.mrb", ...] }
      #
      # The manifest is only written when at least one plug-in was
      # staged, so absence of the file means "no plug-ins" — boot
      # scripts can fetch with a graceful 404 fallback.
      def write_plugins_manifest!(plugin_urls)
        return if plugin_urls.empty?

        require 'json'
        manifest_path = File.join(@output_dir, 'lilac.plugins.json')
        File.write(manifest_path, JSON.pretty_generate(plugins: plugin_urls) + "\n")
      end

      def render_named_template(template_name, body_html)
        %(<template data-template="#{escape_attr(template_name)}">#{body_html}</template>)
      end

      def render_script(ruby_source)
        "<script type=\"text/ruby\">\n#{ruby_source}\n</script>"
      end

      def escape_attr(value)
        value.gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;')
      end

      def inject_before_body_close(html, injection)
        # Prefer the last </body> so any earlier mention (e.g. inside a
        # <pre> code example) doesn't get hijacked.
        idx = html.rindex(%r{</body>}i)
        return "#{html}\n#{injection}" unless idx

        "#{html[0...idx]}#{injection}\n#{html[idx..]}"
      end

      def output_path_for(page_path)
        rel = Pathname.new(page_path).relative_path_from(Pathname.new(@pages_dir))
        File.join(@output_dir, rel.to_s)
      end
    end
  end
end
