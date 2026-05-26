# frozen_string_literal: true

require_relative 'codegen'
require_relative 'component_name'
require_relative '../lint/cross_ref_linter'

module Lilac
  module CLI
    # Per-page assembly of the Ruby source one bundle script contains:
    # for every component used on the page, the pre-compiled
    # `Lilac::Bindings::<Class>` module (from `Codegen.generate`) joined
    # to the user-authored script body. Runs `CrossRefLinter` ahead of
    # codegen so any signal/method mismatch surfaces as a build error
    # before the bytecode pass.
    #
    # Used only by `PageCompiler` (per-page injection). The :bundle
    # delivery writer takes a leaner path through `BundleAssetWriter`
    # because the bundle file gathers ALL components rather than the
    # "used on this page" subset, and skips the lint pass entirely.
    class ComponentScriptsAssembler
      def initialize(template_cache:, codegen:)
        @template_cache = template_cache
        @codegen = codegen
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

        # Generated FIRST so that `Lilac::Bindings::<Class>` is
        # defined before the user script's `Lilac.start` mounts
        # components and calls `bind_template_hook`. The component
        # base's `lookup_codegen_bindings` resolves and includes the
        # module on demand at that point.
        [generate_bindings(name, parsed), user_script].reject(&:empty?).join("\n\n")
      end

      # Cross-reference lint runs before codegen so any warnings
      # appear ahead of generated source in build output, matching
      # the user's mental order ("first the diagnostics, then the
      # result"). Errors raise — warnings go to stderr and the build
      # carries on inside CrossRefLinter.
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

      def generate_bindings(name, parsed)
        # Runtime scanner mode (codegen: :off) — leave directive
        # interpretation to the runtime at mount time. Both targets
        # otherwise rely on Component#bind_template_hook to look up
        # `Lilac::Bindings::<Class>` by name; the explicit
        # `<Class>.include(...)` line is dropped because it would
        # either NameError (codegen runs before the class def) or
        # run too late (after the user's `Lilac.start`).
        return '' if @codegen == :off

        Codegen.generate(
          component_name: name,
          directives: parsed[:default_directives],
          source_path: parsed[:source_path],
          emit_include: false
        ).strip
      end
    end
  end
end
