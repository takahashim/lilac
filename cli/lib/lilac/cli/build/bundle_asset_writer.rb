# frozen_string_literal: true

require 'fileutils'
require_relative 'codegen'
require_relative 'html_emitter'

module Lilac
  module CLI
    # In :bundle delivery mode, emits all components' default templates,
    # named templates, and Ruby scripts into a single
    # `dist/lilac.bundle.html`. Pages reference it via
    # `<link rel="lilac-bundle">`, and PageCompiler's boot module / the
    # runtime registry fetches it before mount.
    #
    # For the :compiled target, scripts are NOT inlined into the bundle
    # (the compiled wasm has no parser to evaluate text/ruby). Instead
    # they are aggregated and compiled into a single `bundle.mrb`, plus
    # a tiny standalone `start_only.mrb` (just `Lilac.start`) — both
    # filenames ride on the returned `BundleAssets` so PageCompiler can
    # chain them into each page's boot module.
    #
    # See decisions §20.6 (Lilac.start placement) and the bundle-fetch
    # proposal for the rationale behind splitting bundle.mrb /
    # start_only.mrb instead of appending `Lilac.start` to the bundle.
    class BundleAssetWriter
      # Build-level artifacts handed back to the orchestrator (Builder)
      # and forwarded into the `BuildContext` PageCompiler reads. `url`
      # is what gets stamped into each page's `<link rel="lilac-bundle">`;
      # the two `.mrb` filenames are only populated when
      # `target == :compiled` (otherwise scripts go into the bundle.html
      # itself as <script type="text/ruby">).
      BundleAssets = Struct.new(:url, :bundle_mrb, :start_only_mrb, keyword_init: true)

      BUNDLE_FILENAME = 'lilac.bundle.html'
      BUNDLE_URL = "/#{BUNDLE_FILENAME}"

      def initialize(components:, template_cache:, target:, codegen:,
                     output_dir:, bytecode_builder:)
        @components = components
        @template_cache = template_cache
        @target = target
        @codegen = codegen
        @output_dir = output_dir
        @bytecode_builder = bytecode_builder
      end

      # Writes the bundle file and (for :compiled) compiles bundle.mrb +
      # start_only.mrb. Returns a `BundleAssets`, or nil when there are
      # no components to bundle.
      def write!
        return nil if @components.empty?

        parts, compiled_scripts = assemble_parts
        write_html_file!(parts)
        bundle_mrb, start_only_mrb = compile_compiled_scripts!(compiled_scripts)

        BundleAssets.new(
          url: BUNDLE_URL,
          bundle_mrb: bundle_mrb,
          start_only_mrb: start_only_mrb
        )
      end

      private

      # Walks every component once, producing the HTML `parts` that go
      # into bundle.html and the deferred `compiled_scripts` list that
      # gets compiled to bytecode (only on :compiled target — :full puts
      # the script bodies inline into `parts` as <script type="text/ruby">).
      def assemble_parts
        parts = []
        compiled_scripts = []

        @components.each do |name, comp|
          parsed = @template_cache.fetch(name, comp)

          # Default template
          parts << "<template>#{parsed[:default_html]}</template>"

          # Named templates (user-defined + synthetic data-each rows)
          parsed[:named].each do |nt|
            parts << HtmlEmitter.render_named_template(nt.name, nt.html)
          end

          # Script (codegen + user code) — skipped entirely when no
          # user_script exists since there's nothing to wire.
          user_script = comp.script.strip
          next if user_script.empty?

          full_script = [generated_bindings_for(name, parsed), user_script].reject(&:empty?).join("\n\n")

          if @target == :compiled
            # Defer: scripts get aggregated into one .mrb below.
            compiled_scripts << full_script
          else
            parts << HtmlEmitter.render_script(full_script)
          end
        end

        [parts, compiled_scripts]
      end

      # Pre-compiled `Lilac::Bindings::<Class>` module source for one
      # component, or `''` when codegen is disabled (runtime scanner
      # mode for parity testing).
      def generated_bindings_for(name, parsed)
        return '' if @codegen == :off

        Codegen.generate(
          component_name: name,
          directives: parsed[:default_directives],
          source_path: parsed[:source_path],
          emit_include: false
        ).strip
      end

      def write_html_file!(parts)
        FileUtils.mkdir_p(@output_dir)
        bundle_path = File.join(@output_dir, BUNDLE_FILENAME)
        File.write(bundle_path, parts.join("\n") + "\n")
      end

      # :compiled — compile aggregated scripts into a .mrb that the
      # page boot module loads via loadBytecode. `Lilac.start` is NOT
      # appended to the bundle: when a page has its own page-inline
      # .mrb chained after the bundle, that one terminates with
      # `Lilac.start`; when a page has only the bundle, we emit a
      # tiny start-only .mrb so the chain still ends with `Lilac.start`
      # running once after both class definitions and any page-local
      # scripts are loaded.
      def compile_compiled_scripts!(compiled_scripts)
        return [nil, nil] unless @target == :compiled && !compiled_scripts.empty?

        bundle_mrb = @bytecode_builder.build(
          compiled_scripts.join("\n\n"), source_label: 'bundle'
        )
        # Standalone `Lilac.start` .mrb, shared by all pages that have
        # no page-inline scripts. Content-hashed so cache reuses it
        # across pages.
        start_only_mrb = @bytecode_builder.build(
          'Lilac.start', source_label: 'bundle-start'
        )
        [bundle_mrb, start_only_mrb]
      end
    end
  end
end
