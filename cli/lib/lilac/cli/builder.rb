# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "sfc"
require_relative "template_ast"
require_relative "codegen"
require_relative "component_name"
require_relative "cross_ref_linter"
require_relative "bytecode_builder"

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

      LIVE_RELOAD_SCRIPT = <<~HTML.freeze
        <script>
          // lilac dev: live reload via SSE
          new EventSource("/__lilac/livereload").addEventListener("message", () => location.reload());
        </script>
      HTML

      def initialize(components_dir:, pages_dir:, output_dir:, public_dir: nil,
                     live_reload: false, codegen: :auto,
                     target: :full, mrbc_path: nil)
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
        # (vm.loadIrep). The compiled target shaves ~32% off the brotli
        # bundle but requires `mrbc` available at build time. See
        # `BytecodeBuilder` for path discovery.
        @target = target
        @mrbc_path = mrbc_path
      end

      def build
        components = load_components
        pages = Dir.glob(File.join(@pages_dir, "**", "*.html"))
        raise Error, "No pages found under #{@pages_dir.inspect}" if pages.empty?

        public_files = mirror_public_files

        # Caches per component name to avoid re-parsing template bodies
        # when the same component appears on multiple pages.
        @template_ast_cache = {}

        pages.each do |page_path|
          build_page(page_path, components)
        end

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
              html: st.html,
            )
          end

          {
            default_html: default_results.map(&:html).join.strip,
            default_directives: default_results.flat_map(&:directives),
            default_refs_map: default_results.map(&:refs_map).reduce({}, :merge),
            named: named + synthetic,
            source_path: component.path,
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

        copied = 0
        Dir.glob(File.join(@public_dir, "**", "*"), File::FNM_DOTMATCH).each do |source|
          # File.file? already filters out the `.` / `..` directory
          # entries that FNM_DOTMATCH surfaces, so no extra guard needed.
          next unless File.file?(source)
          next if EXCLUDED_BASENAMES.include?(File.basename(source))

          rel = Pathname.new(source).relative_path_from(Pathname.new(@public_dir)).to_s
          target = File.join(@output_dir, rel)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(source, target)
          copied += 1
        end
        copied
      end

      def load_components
        Dir.glob(File.join(@components_dir, "**", "*.lil")).to_h do |path|
          [File.basename(path, ".lil"), SFC.parse_file(path)]
        end
      end

      def build_page(page_path, components)
        html = File.read(page_path)
        used = []

        html = html.gsub(COMPONENT_PLACEHOLDER) do
          # Capture 1 = double-quoted name; capture 2 = single-quoted name.
          name = Regexp.last_match(1) || Regexp.last_match(2)
          comp = components[name] || raise(Error, "Unknown component: #{name.inspect} (referenced in #{page_path})")
          used << name
          default_markup(name, comp)
        end

        injection = build_injection(used.uniq, components)
        html = inject_before_body_close(html, injection) unless injection.empty?

        File.write(output_path_for(page_path).tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, html)
      end

      def default_markup(name, component)
        template_ast_for(name, component)[:default_html]
      end

      def build_injection(used_names, components)
        named_templates = used_names.flat_map { |name|
          parsed = template_ast_for(name, components[name])
          parsed[:named].map { |nt| render_named_template(nt.name, nt.html) }
        }

        scripts = used_names.map { |name|
          comp = components[name]
          parsed = template_ast_for(name, comp)
          user_script = comp.script.strip
          # Cross-reference lint runs before codegen so any warnings
          # appear ahead of generated source in build output, matching
          # the user's mental order ("first the diagnostics, then the
          # result"). Non-fatal — warnings go to stderr and the build
          # carries on.
          lint_result = CrossRefLinter.lint(
            script_text: user_script,
            directives: parsed[:default_directives],
            refs_map: parsed[:default_refs_map],
            component_name: ComponentName.new(name).ruby_class,
            file: parsed[:source_path] ? File.basename(parsed[:source_path]) : "(template)",
          )
          # Fatal cross-ref violations (e.g. data-button referencing an
          # undeclared `f.button :X`) abort the build — runtime would
          # raise on first user interaction, so the build/runtime
          # severity stays aligned (decisions §6).
          if lint_result.errors?
            raise Error, "build failed: #{lint_result.errors} lint error(s) in template; see warnings above."
          end
          generated =
            if @codegen == :off
              # Runtime scanner mode: emit no bind_template_hook,
              # leaving the runtime to interpret data-* at mount.
              ""
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
                emit_include: false,
              ).strip
            end
          # Generated FIRST so that `Lilac::Bindings::<Class>` is
          # defined before the user script's `Lilac.start` mounts
          # components and calls `bind_template_hook`. The component
          # base's `lookup_codegen_bindings` resolves and includes the
          # module on demand at that point.
          parts = [generated, user_script]
          parts.reject(&:empty?).join("\n\n")
        }.reject(&:empty?)

        ruby_source = scripts.join("\n\n")
        script_block =
          if scripts.empty?
            nil
          elsif @target == :compiled
            # Compile the aggregated Ruby to `.mrb` bytecode and emit a
            # module script that fetches the bytecode + boots the
            # lilac-compiled wasm. The `data-lilac-bootstrap` attribute
            # marks the tag so a future asset-pipeline pass can rewrite
            # the URLs.
            mrb_file = bytecode_builder.build(ruby_source, source_label: "page bundle")
            render_compiled_boot_module(mrb_file)
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
        )
      end

      # Emits the module script that loads `.mrb` bytecode and boots
      # the lilac-compiled wasm. Vendor path defaults to
      # `./vendor/lilac-compiled/` (mirrored from `public/vendor/...`
      # at build time — same convention as Vite / Eleventy's `public/`
      # passthrough).
      def render_compiled_boot_module(mrb_filename)
        <<~HTML.strip
          <script type="module" data-lilac-bootstrap>
            import { boot } from "./vendor/lilac-compiled/index.js";
            const bytecode = new Uint8Array(
              await (await fetch("./#{mrb_filename}")).arrayBuffer()
            );
            await boot({ bytecode });
          </script>
        HTML
      end

      def render_named_template(template_name, body_html)
        %(<template data-template="#{escape_attr(template_name)}">#{body_html}</template>)
      end

      def render_script(ruby_source)
        "<script type=\"text/ruby\">\n#{ruby_source}\n</script>"
      end

      def escape_attr(value)
        value.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;")
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
