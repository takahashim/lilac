# frozen_string_literal: true

require_relative 'component_name'
require_relative '../lint/cross_ref_linter'

module Lilac
  module CLI
    # Per-page assembly of the Ruby source one bundle script contains:
    # the user-authored `<script>` body of every component used on the
    # page. Binding is scanner-canonical (the runtime scanner wires
    # `data-*` at mount), so no `Lilac::Bindings::<Class>` codegen is
    # emitted here — this class only runs `CrossRefLinter` (to surface
    # signal/method mismatches as build errors) and returns the user
    # script unchanged.
    #
    # Used only by `PageCompiler` (per-page injection). The :bundle
    # delivery writer takes a leaner path through `BundleAssetWriter`
    # because the bundle file gathers ALL components rather than the
    # "used on this page" subset, and skips the lint pass entirely.
    class ComponentScriptsAssembler
      def initialize(template_cache:)
        @template_cache = template_cache
      end

      # Returns `Array<String>` — one Ruby source chunk per component
      # that had a non-empty user script. Order matches `used_names`
      # so that any user-side dependency on declaration order (e.g.
      # subclass after parent) is preserved across the bundle.
      #
      # `synthesized_names` marks components that originate from a
      # page-inline `<X data-component=...>` (their `comp.script` slot
      # is empty by construction; the actual class body lives in the
      # page's `<script type="text/ruby">` blocks). For those the
      # cross-ref linter reads the page-level inline Ruby instead so
      # `@signal` / `def method` lookups resolve.
      def assemble(used_names, components, synthesized_names:, page_inline_scripts:)
        synth_lint_script = page_inline_scripts.join("\n\n")
        used_names.map do |name|
          assemble_one(name, components[name], synthesized_names, synth_lint_script)
        end.reject(&:empty?)
      end

      private

      def assemble_one(name, comp, synthesized_names, synth_lint_script)
        parsed = @template_cache.fetch(name, comp)
        user_script = comp.script.strip
        lint_script = synthesized_names.include?(name) ? synth_lint_script : user_script

        run_lint!(name, parsed, lint_script)

        # Scanner-canonical: no codegen module is emitted. The user
        # script is returned as-is; the runtime scanner wires the
        # component's `data-*` directives at mount.
        user_script
      end

      # Cross-reference lint surfaces signal/method mismatches as build
      # errors before the bytecode pass. Errors raise — warnings go to
      # stderr and the build carries on inside CrossRefLinter.
      def run_lint!(name, parsed, lint_script)
        result = CrossRefLinter.lint(
          script_text: lint_script,
          directives: parsed[:default_directives],
          refs_map: parsed[:default_refs_map],
          component_name: ComponentName.new(name).ruby_class,
          file: parsed[:source_path] ? File.basename(parsed[:source_path]) : '(template)'
        )
        return unless result.errors?

        raise Builder::Error,
              "build failed: #{result.errors} lint error(s) in template; see warnings above."
      end
    end
  end
end
