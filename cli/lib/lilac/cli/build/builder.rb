# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require_relative 'sfc'
require_relative 'template_ast'
require_relative 'codegen'
require_relative 'component_name'
require_relative '../lint/cross_ref_linter'
require_relative '../lint/build_linter'
require_relative 'bytecode_builder'
require_relative 'form_extension'
require_relative '../live_reload'

module Lilac
  module CLI
    # Reads `.lil` components and `.html` pages, then emits static HTML.
    #
    # Page authors mark component insertion points with
    #   <div data-use="counter"></div>
    # The runtime injects markup from the matching <template> +
    # <div data-component="counter"> definition that the build emits.
    # Named sub-templates and Ruby class scripts from all components used
    # on the page are injected once each before `</body>`.
    #
    # Component file naming: `components/<data-component-name>.lil`. The file's
    # basename is taken verbatim as the component name, so
    # `admin--user-card.lil` matches `<div data-use="admin--user-card">`
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

      # Matches `data-use="X"` / `data-use='X'` attribute values on any
      # element. We don't need to know which tag carries the attribute —
      # just collect the referenced component names so the build can
      # bundle their templates + scripts into the page.
      DATA_USE_PATTERN = %r{
        \bdata-use\s*=\s*(?:"([^"]+)"|'([^']+)')
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

      def initialize(components_dir:, pages_dir:, output_dir:, public_dir: nil,
                     live_reload: false, codegen: :auto,
                     target: :full, mrbc_path: nil,
                     lilac_compiled_path: nil, mruby_wasm_js_path: nil,
                     packages: [],
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
        # Pre-compiled Lilac package `.mrb` paths (absolute). For both
        # `:compiled` and `:full` builds these get staged under
        # `dist/packages/`; `:compiled` injects loadBytecode into the
        # generated boot module directly, `:full` writes a
        # `dist/lilac.packages.json` manifest the scaffold boot fetches.
        # See decisions §25 / §26.
        @packages            = Array(packages).map { |p| File.expand_path(p) }
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

        # Resolve and stage package `.mrb` files once for the build —
        # the URLs are stable across pages so each page's boot module
        # can reference the same set.
        @package_dist_urls = stage_packages!
        # `:full` target doesn't generate its own boot module (user's
        # scaffold-provided `<script type="module">` owns boot), so we
        # surface the package list as a `lilac.packages.json` manifest
        # the user-side boot can fetch. `:compiled` doesn't need this —
        # the generated `data-lilac-bootstrap` module inlines the URLs.
        write_packages_manifest!(@package_dist_urls) if @target == :full

        # Caches per component name to avoid re-parsing template bodies
        # when the same component appears on multiple pages.
        @template_ast_cache = {}

        # Per-build linter holds page-inline component signatures for
        # cross-page drift detection and runs class-name collision
        # checks. Reset on each `build` so repeated invocations don't
        # accumulate state across builds.
        @build_linter = BuildLinter.new

        pages.each do |page_path|
          build_page(page_path, components)
        end

        @build_linter.warn_cross_page_signature_drift!

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
        @build_linter.check_class_name_collisions!(page_inline_scripts, components, synthesized_names, page_path)

        used = used_inline.dup
        # Page references to components via data-use="X" — the runtime
        # injects markup from the matching <template>...<div data-component="X">
        # definition that build_injection emits below. We only need to
        # record each X in `used` so its template + script land in the
        # injection bundle.
        html.scan(DATA_USE_PATTERN) do |dq, sq|
          name = dq || sq
          unless components.key?(name)
            raise Error,
                  "Unknown component referenced by data-use=#{name.inspect} in #{page_path} " \
                  "(no components/#{name}.lil and no page-inline data-component=#{name.inspect})"
          end
          used << name
        end

        injection = build_injection(used.uniq, components,
                                    page_inline_scripts: page_inline_scripts,
                                    synthesized_names: synthesized_names,
                                    page_path: page_path)
        html = inject_before_body_close(html, injection) unless injection.empty?

        File.write(output_path_for(page_path).tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, html)
      end

      # Lifts page-inline `data-component` elements into the same
      # codegen pipeline that `.lil` components go through. The element
      # stays where the user wrote it and the runtime mounts directly
      # via the `data-component` attribute.
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
          @build_linter&.record_inline_signature(name, body_html, page_path)
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

        # Default templates: emit one <template><div data-component="X">...</div></template>
        # per used component (skipping synthesized in-memory components,
        # which already have their markup written inline on the page).
        # The runtime registry consults these templates to fill empty
        # data-use="X" elements at mount time.
        default_templates = used_names.reject { |n| synthesized_names.include?(n) }.map do |name|
          parsed = template_ast_for(name, components[name])
          render_default_template(name, parsed[:default_html])
        end

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
        #   (scaffold `boot.js`, lilac-full's GitHub Pages CDN `boot`, …)
        #   runs `vm.eval("Lilac.start")` at the tail of its eval loop
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
            render_compiled_boot_module(mrb_file, @package_dist_urls || [])
          else
            render_script(ruby_source)
          end

        # Live reload is dev-only; the `lilac build` command leaves it
        # off. When on, the snippet opens an SSE connection back to the
        # dev server and reloads the page on any "message" event.
        parts = [default_templates, named_templates, script_block]
        parts << LiveReload::SCRIPT if @live_reload
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
      def render_compiled_boot_module(mrb_filename, package_urls = [])
        # Package `.mrb` bundles load BEFORE the user bytecode so any
        # `Scanner.register("ClassName")` calls (and the Handler classes
        # they refer to) are ready by the time component mount runs.
        # Mirrors the load ordering in `npm/lilac-compiled/index.js`'s
        # boot helper.
        # The heredoc below uses 2-space indent (squiggly heredoc strips
        # the common leading whitespace). Package load lines slot in
        # before `const bytecode = ...` at the same depth.
        package_loads = package_urls.map do |url|
          "vm.loadBytecode(new Uint8Array(await (await fetch(#{url.inspect})).arrayBuffer()));"
        end.join("\n  ")
        package_block = package_loads.empty? ? '' : "#{package_loads}\n  "
        <<~HTML.strip
          <script type="module" data-lilac-bootstrap>
            import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js";
            const vm = await createVM({ wasm: "./vendor/lilac-compiled/lilac.wasm" });
            #{package_block}const bytecode = new Uint8Array(
              await (await fetch("./#{mrb_filename}")).arrayBuffer()
            );
            vm.loadBytecode(bytecode);
          </script>
        HTML
      end

      # Stage package `.mrb` files under `dist/packages/` and return the
      # page-relative URLs the boot script should `fetch`. Two input
      # channels merge here (decisions §25 / §26):
      #
      #   1. **Bundler auto-discovery** — `PackageDiscovery.run` finds
      #      gems whose gemspec declares `metadata["lilac_package"] = "true"`.
      #      Each gem's `mrblib/*.rb` is compiled locally to `.mrb` so the
      #      mruby version matches the vendored core wasm.
      #   2. **Explicit `c.packages = [...paths]`** — pre-compiled `.mrb`
      #      files. Useful for advanced overrides (custom package not in
      #      a gem, vendored fork, etc.).
      #
      # Both `:full` and `:compiled` targets benefit from packages —
      # `:compiled` injects loadBytecode into the generated boot module
      # directly, `:full` writes a `lilac.packages.json` manifest that
      # the user's hand-rolled (scaffold) boot script reads to load each
      # package ahead of `evalScript`.
      def stage_packages!
        return [] if @packages.empty? && discovered_packages.empty?

        dest_dir = File.join(@output_dir, 'packages')
        FileUtils.mkdir_p(dest_dir)

        urls = []
        # Auto-discovered gem-based packages first. Compile each gem's
        # mrblib source set to a single `.mrb` named after the gem so
        # filename collisions with explicit override paths are easy to
        # spot.
        discovered_packages.each do |discovered|
          bytes = compile_package_source(discovered.mrblib_files, source_label: discovered.name)
          filename = "#{discovered.name}.mrb"
          File.binwrite(File.join(dest_dir, filename), bytes)
          urls << "./packages/#{filename}"
        end
        # Explicit override paths next — already-compiled `.mrb` files
        # the user pointed at directly via `c.packages`.
        @packages.each do |src|
          raise Error, "Lilac package `.mrb` not found: #{src}" unless File.file?(src)

          basename = File.basename(src)
          FileUtils.cp(src, File.join(dest_dir, basename))
          urls << "./packages/#{basename}"
        end
        urls.uniq
      end

      # Cached `PackageDiscovery` result so multi-page builds discover
      # once. Empty list outside a Bundler context.
      def discovered_packages
        @discovered_packages ||= PackageDiscovery.run
      end

      # Compile concatenated mrblib source to bytecode via the existing
      # `BytecodeBuilder` backend chain (binary mrbc → wasm-driven mrbc
      # → $PATH). Mirrors `lilac package-build`'s aggregation rule:
      # alphabetical concat separated by newlines.
      def compile_package_source(mrblib_files, source_label:)
        source = mrblib_files.map { |f| File.read(f) }.join("\n")
        bytecode_builder.compile_to_bytes(source, source_label: "package #{source_label}")
      end

      # Write `dist/lilac.packages.json` so a scaffold-style boot script
      # can fetch the manifest and `loadBytecode` each entry before
      # evaluating `<script type="text/ruby">` blocks. Format:
      #
      #   { "packages": ["./packages/lilac-extras.mrb", ...] }
      #
      # The manifest is only written when at least one package was
      # staged, so absence of the file means "no packages" — boot
      # scripts can fetch with a graceful 404 fallback.
      def write_packages_manifest!(package_urls)
        return if package_urls.empty?

        require 'json'
        manifest_path = File.join(@output_dir, 'lilac.packages.json')
        File.write(manifest_path, JSON.pretty_generate(packages: package_urls) + "\n")
      end

      def render_named_template(template_name, body_html)
        %(<template data-template="#{escape_attr(template_name)}">#{body_html}</template>)
      end

      # Emit a <template> wrapping the component's default markup. The
      # `default_html` already contains the outer `<div data-component="X">`
      # element from the .lil source, so we don't add another wrapper —
      # just surround it with <template> so the runtime registry can pick
      # it up as the source for data-use="X" injections.
      def render_default_template(_name, default_html)
        %(<template>#{default_html}</template>)
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
