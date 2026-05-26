# frozen_string_literal: true

require_relative "script_analyzer"
require_relative "lint_warning"
require_relative "../source_location"
require_relative "../../directives" # Lilac::Directives::ClassParser

module Lilac
  module CLI
    # Build-time cross-reference linter. Compares identifiers used in
    # template directives (ivars in `data-text`, methods in
    # `data-on-X`, etc.) against the declarations extracted from
    # `<script type="text/ruby">` by ScriptAnalyzer (AST-based).
    # Undeclared references emit a diagnostic to stderr (or any
    # caller-provided IO).
    #
    # Pure scan: never raises. Returns a `Result(warnings:, errors:)`
    # struct — the caller fails the build when `errors > 0`. All
    # current checks are warning-level; `errors` is retained for the
    # Result contract so future fatal checks can fail the build
    # without reshaping the API.
    #
    # Class-shaped (instead of a module of `self.lint_*` methods) so
    # the per-call state — analysis, directives, refs_map, component
    # name, file, IO — lives in ivars rather than being threaded
    # through every helper as 5 positional arguments.
    class CrossRefLinter
      # Tunable: maximum Levenshtein distance for the "Did you mean?"
      # suggestion to be offered. 2 keeps it useful for typos without
      # surfacing unrelated names.
      SUGGESTION_MAX_DISTANCE = 2

      # Aggregate counts returned from `lint`. `errors` tracks fatal
      # violations (build should fail); `warnings` tracks non-fatal
      # ones. `total` is the "any diagnostic count" sum used by callers
      # that don't need to distinguish severity.
      Result = Struct.new(:warnings, :errors, keyword_init: true) do
        def total
          warnings + errors
        end

        def errors?
          errors.positive?
        end
      end

      # Methods the framework calls without an explicit `def name` →
      # `data-on-X` wiring; never flag them as dead even if no
      # template directive references them.
      LIFECYCLE_METHODS = %w[
        setup initialize bind_template_hook prepare_setup
      ].freeze

      # `data-ref` names that collide with Object / Kernel methods —
      # `refs.X` then dispatches to the Ruby method instead of
      # `Refs#method_missing`, producing a confusing NoMethodError or
      # silent wrong behaviour.
      RESERVED_REF_NAMES = %w[
        p puts print pp format sprintf printf
        gets getc
        raise throw catch fail exit abort
        lambda proc method methods
        caller inspect class send public_send tap then itself
        nil? frozen? is_a? kind_of? respond_to? object_id hash eql? to_s freeze
      ].freeze

      # Public entry. Keeps the kwargs-only call shape from before the
      # class refactor so existing callers (PageCompiler's assembler,
      # tests) are unchanged.
      def self.lint(script_text:, directives:, component_name:, file:, refs_map: {}, out: $stderr)
        new(
          script_text: script_text, directives: directives,
          component_name: component_name, file: file,
          refs_map: refs_map, out: out
        ).run
      end

      def initialize(script_text:, directives:, component_name:, file:, refs_map: {}, out: $stderr)
        # Narrow the AST walk to the named class so a multi-class
        # script (e.g. a page-inline page with sibling components, or
        # a `.lil` that declares helper classes alongside the
        # component) doesn't bleed sibling-class declarations into
        # this component's dead-signal / dead-method checks.
        @analysis = ScriptAnalyzer.analyze(script_text, class_name: component_name)
        @directives = directives
        @component_name = component_name
        @file = file
        @refs_map = refs_map
        @out = out
      end

      def run
        warnings = 0
        warnings += lint_undeclared_signals
        warnings += lint_undefined_methods
        warnings += lint_each_without_key
        warnings += lint_reserved_ref_names
        warnings += lint_dead_signals
        warnings += lint_dead_methods
        Result.new(warnings: warnings, errors: 0)
      end

      private

      def lint_undeclared_signals
        warnings = 0
        @directives.each do |directive|
          ivars_in_directive(directive).each do |ivar|
            next if @analysis.declares_signal?(ivar)
            # Soft fallback: any `@x = ...` somewhere in the script
            # could be a helper-style signal init the static check
            # can't see — suppress the warning rather than blame the
            # user for a pattern Ruby allows.
            next if @analysis.assigns_ivar?(ivar)

            emit_signal_warning(directive, ivar)
            warnings += 1
          end
        end
        warnings
      end

      def lint_undefined_methods
        warnings = 0
        @directives.each do |directive|
          method = method_in_directive(directive)
          next unless method
          next if @analysis.declares_method?(method)

          emit_method_warning(directive, method)
          warnings += 1
        end
        warnings
      end

      def lint_each_without_key
        keyed = @directives.select { |d| d.kind == :key }.map(&:ref_id)
        warnings = 0
        @directives.each do |d|
          next unless d.kind == :each
          next if keyed.include?(d.ref_id)

          emit_each_without_key_warning(d)
          warnings += 1
        end
        warnings
      end

      def lint_reserved_ref_names
        warnings = 0
        @refs_map.each do |name, info|
          next unless RESERVED_REF_NAMES.include?(name)

          emit_reserved_ref_warning(name, info[:line])
          warnings += 1
        end
        warnings
      end

      # A signal is dead if it's declared but neither read anywhere in
      # the script (e.g. inside `computed { @x.value }`, another
      # method body, etc.) NOR referenced by any template directive.
      def lint_dead_signals
        template_refs = collect_referenced_ivars
        warnings = 0
        @analysis.declared_signals.each do |ivar, line|
          next if @analysis.references_ivar?(ivar)
          next if template_refs.include?(ivar)

          emit_dead_signal_warning(ivar, line)
          warnings += 1
        end
        warnings
      end

      # A method is dead if it's declared but neither called in the
      # script (including `send(:name)`, `method(:name)`, helper
      # delegation) NOR referenced by any `data-on-X` directive, and
      # it isn't a framework-called lifecycle method.
      def lint_dead_methods
        template_refs = collect_referenced_methods
        warnings = 0
        @analysis.declared_methods.each do |method, line|
          next if LIFECYCLE_METHODS.include?(method)
          next if @analysis.calls_method?(method)
          next if template_refs.include?(method)

          emit_dead_method_warning(method, line)
          warnings += 1
        end
        warnings
      end

      # All ivars referenced by a single directive. For most kinds the
      # directive value is itself the ivar (or a bare ident which we
      # skip). For data-class, multiple ivars hide inside the hash.
      def ivars_in_directive(directive)
        case directive.kind
        when :text, :unsafe_html, :show, :hide, :each, :attr, :css
          value = directive.value.to_s.strip
          value.start_with?("@") ? [value] : []
        when :class_
          pairs =
            begin
              Lilac::Directives::ClassParser.parse(directive.value)
            rescue Lilac::Directives::ClassParser::Error
              # Codegen will surface the parse error as a build error;
              # we silently skip lint here so the user sees one clear
              # message instead of two competing ones.
              []
            end
          pairs.map { |_, v| v.strip }.select { |v| v.start_with?("@") }
        else
          []
        end
      end

      def method_in_directive(directive)
        return nil unless directive.kind == :on

        directive.value.to_s.strip
      end

      def collect_referenced_ivars
        @directives.flat_map { |d| ivars_in_directive(d) }.uniq
      end

      def collect_referenced_methods
        @directives.filter_map { |d| method_in_directive(d) }.uniq
      end

      def emit_signal_warning(directive, ivar)
        declared = @analysis.declared_signals.keys
        emit(LintWarning.new(
          at: directive.source_location(@file),
          body: "Signal #{ivar} is not declared via signal/computed/resource/persistent_signal " \
                "in #{@component_name}. Possible typo or dynamic declaration.",
          declared_label: "Declared signals", declared: declared,
          suggestion: suggest(ivar, declared),
        ))
      end

      def emit_method_warning(directive, method)
        declared = @analysis.declared_methods.keys
        emit(LintWarning.new(
          at: directive.source_location(@file),
          body: "Method `#{method}` (referenced by data-on-#{directive.name}) is not defined " \
                "in #{@component_name}. Possible typo or external delegation.",
          declared_label: "Declared methods", declared: declared,
          suggestion: suggest(method, declared),
        ))
      end

      def emit_each_without_key_warning(directive)
        emit(LintWarning.new(
          at: directive.source_location(@file),
          body: "data-each without data-key falls back to object_id, which causes unstable " \
                "re-renders when the list is rebuilt from raw data.",
          suggestion: "Add `data-key=\"id\"` (or another stable field) on the same element.",
        ))
      end

      def emit_reserved_ref_warning(name, line)
        emit(LintWarning.new(
          at: SourceLocation.new(file: @file, line: line),
          body: "data-ref #{name.inspect} collides with a Ruby Kernel/Object method. " \
                "`refs.#{name}` will dispatch to the built-in method instead of the ref lookup.",
          suggestion: "Rename the ref (e.g. `#{name}_el`) or access it via `refs[:#{name}]`.",
        ))
      end

      def emit_dead_signal_warning(ivar, line)
        emit(LintWarning.new(
          at: SourceLocation.new(file: @file, line: line),
          body: "Signal #{ivar} is declared in #{@component_name} but never read — " \
                "no `#{ivar}` reference in the script and no template directive uses it.",
          suggestion: "Remove the declaration if it's unused, or wire it into a directive.",
        ))
      end

      def emit_dead_method_warning(method, line)
        emit(LintWarning.new(
          at: SourceLocation.new(file: @file, line: line),
          body: "Method `#{method}` is defined in #{@component_name} but never called — " \
                "no call in the script and no `data-on-X` directive references it.",
          suggestion: "Remove if unused, or wire it via `data-on-<event>=\"#{method}\"`.",
        ))
      end

      # Writes the warning followed by a blank line so consecutive
      # warnings stay visually separated in stderr output.
      def emit(warning)
        @out.puts(warning.to_s)
        @out.puts
      end

      # Closest declared name within SUGGESTION_MAX_DISTANCE, or nil.
      # Wrapped as "Did you mean: X?" by the caller; returns just the
      # candidate name (or nil) so the call sites read symmetrically.
      def suggest(needle, declared)
        candidate = nearest(needle, declared)
        candidate && "Did you mean: #{candidate}?"
      end

      def nearest(needle, haystack)
        return nil if haystack.empty?

        candidate, dist = haystack.map { |c| [c, levenshtein(needle, c)] }.min_by { |_, d| d }
        dist <= SUGGESTION_MAX_DISTANCE ? candidate : nil
      end

      # Standard Levenshtein edit distance — insertions, deletions,
      # substitutions. Damerau's transposition adds noise for the
      # typo set we actually see (off-by-one letter swaps), so the
      # plainer metric is enough.
      def levenshtein(a, b)
        return b.length if a.empty?
        return a.length if b.empty?

        m = a.length
        n = b.length
        dp = (0..n).to_a
        (1..m).each do |i|
          prev = dp[0]
          dp[0] = i
          (1..n).each do |j|
            tmp = dp[j]
            dp[j] = a[i - 1] == b[j - 1] ? prev : [prev, dp[j], dp[j - 1]].min + 1
            prev = tmp
          end
        end
        dp[n]
      end
    end
  end
end
