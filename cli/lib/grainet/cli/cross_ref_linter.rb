# frozen_string_literal: true

require_relative "script_scanner"
require_relative "hash_literal_parser"
require_relative "lint_warning"
require_relative "source_location"

module Grainet
  module CLI
    # Build-time cross-reference linter. Compares identifiers used in
    # template directives (ivars in `data-text`, methods in
    # `data-on-X`, etc.) against the declarations extracted from
    # `<script type="text/ruby">` by ScriptScanner. Undeclared
    # references emit a warning to stderr (or any caller-provided IO);
    # warnings are non-fatal — the build still succeeds.
    #
    # Pure scan: never raises. Returns the count of warnings emitted so
    # callers (e.g. a future `--strict` mode) can decide to exit with
    # a non-zero code based on the result.
    module CrossRefLinter
      # Tunable: maximum Levenshtein distance for the "Did you mean?"
      # suggestion to be offered. 2 keeps it useful for typos without
      # surfacing unrelated names.
      SUGGESTION_MAX_DISTANCE = 2

      # `data-ref` names that collide with Object / Kernel methods —
      # `refs.X` then dispatches to the Ruby method instead of
      # `Refs#method_missing`, producing a confusing NoMethodError or
      # silent wrong behaviour. List is conservative (spec Section 9
      # "data-ref 名と Ruby 標準 method の衝突").
      RESERVED_REF_NAMES = %w[
        p puts print pp format sprintf printf
        gets getc
        raise throw catch fail exit abort
        lambda proc method methods
        caller inspect class send public_send tap then itself
        nil? frozen? is_a? kind_of? respond_to? object_id hash eql? to_s freeze
      ].freeze

      def self.lint(script_text:, directives:, component_name:, file:, refs_map: {}, out: $stderr)
        scan = ScriptScanner.scan(script_text)
        warnings = 0

        warnings += lint_per_directive(scan, directives, component_name, file, out)
        warnings += lint_each_without_key(directives, file, out)
        warnings += lint_reserved_ref_names(refs_map, file, out)
        # Note: dead-code (declared but never template-referenced) is
        # deliberately not enforced — helper methods called from
        # `setup` / other methods and signals consumed only by
        # `computed { ... }` would produce false positives without a
        # proper script-side reference scan.

        warnings
      end

      # Walks each directive once, surfacing undeclared signal/method
      # references and `it` used outside any `data-each`.
      def self.lint_per_directive(scan, directives, component_name, file, out)
        warnings = 0
        directives.each do |directive|
          ivars_in_directive(directive).each do |ivar|
            next if scan.declares_signal?(ivar) || scan.assigns_ivar?(ivar)

            emit_signal_warning(out, directive, ivar, scan.signals, component_name, file)
            warnings += 1
          end
          method = method_in_directive(directive)
          if method && !scan.declares_method?(method)
            emit_method_warning(out, directive, method, scan.methods, component_name, file)
            warnings += 1
          end
          if uses_it_path?(directive) && directive.scope_id.nil?
            emit_it_outside_each_warning(out, directive, file)
            warnings += 1
          end
        end
        warnings
      end

      def self.lint_each_without_key(directives, file, out)
        keyed = directives.select { |d| d.kind == :key }.map(&:ref_id)
        warnings = 0
        directives.each do |d|
          next unless d.kind == :each
          next if keyed.include?(d.ref_id)

          emit_each_without_key_warning(out, d, file)
          warnings += 1
        end
        warnings
      end

      def self.lint_reserved_ref_names(refs_map, file, out)
        warnings = 0
        refs_map.each do |name, info|
          next unless RESERVED_REF_NAMES.include?(name)

          emit_reserved_ref_warning(out, name, info[:line], file)
          warnings += 1
        end
        warnings
      end

      # All ivars referenced by a single directive. For most kinds the
      # directive value is itself the ivar (or an it_path which we
      # skip). For data-class, multiple ivars hide inside the hash.
      def self.ivars_in_directive(directive)
        case directive.kind
        when :text, :unsafe_html, :value, :checked, :show, :hide, :each
          value = directive.value.to_s.strip
          value.start_with?("@") ? [value] : []
        when :attr, :css
          value = directive.value.to_s.strip
          value.start_with?("@") ? [value] : []
        when :class_
          pairs =
            begin
              HashLiteralParser.parse(directive.value)
            rescue HashLiteralParser::Error
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

      def self.method_in_directive(directive)
        return nil unless directive.kind == :on

        directive.value.to_s.strip
      end

      # Returns true if the directive references `it` or `it.field`
      # (used by the it-outside-each check). data-class can carry
      # multiple values; any one being it_path is enough.
      def self.uses_it_path?(directive)
        case directive.kind
        when :text, :unsafe_html, :show, :hide, :attr, :css, :each
          starts_with_it?(directive.value)
        when :class_
          pairs =
            begin
              HashLiteralParser.parse(directive.value)
            rescue HashLiteralParser::Error
              return false
            end
          pairs.any? { |_, v| starts_with_it?(v) }
        else
          false
        end
      end

      def self.starts_with_it?(value)
        s = value.to_s.strip
        s == "it" || s.start_with?("it.")
      end

      def self.emit_signal_warning(out, directive, ivar, declared, component_name, file)
        guess = nearest(ivar, declared)
        emit(out, LintWarning.new(
          at: directive.source_location(file),
          body: "Signal #{ivar} is not declared via signal/computed/resource/persistent_signal " \
                "in #{component_name}. Possible typo or dynamic declaration.",
          declared_label: "Declared signals", declared: declared,
          suggestion: guess && "Did you mean: #{guess}?",
        ))
      end

      def self.emit_method_warning(out, directive, method, declared, component_name, file)
        guess = nearest(method, declared)
        emit(out, LintWarning.new(
          at: directive.source_location(file),
          body: "Method `#{method}` (referenced by data-on-#{directive.name}) is not defined " \
                "in #{component_name}. Possible typo or external delegation.",
          declared_label: "Declared methods", declared: declared,
          suggestion: guess && "Did you mean: #{guess}?",
        ))
      end

      def self.emit_it_outside_each_warning(out, directive, file)
        emit(out, LintWarning.new(
          at: directive.source_location(file),
          body: "`it` referenced outside a data-each. `it` only binds inside an iteration " \
                "body; this directive will fail at runtime.",
          suggestion: "Use an `@ivar` here, or move this element inside a `data-each` element.",
        ))
      end

      def self.emit_each_without_key_warning(out, directive, file)
        emit(out, LintWarning.new(
          at: directive.source_location(file),
          body: "data-each without data-key falls back to object_id, which causes unstable " \
                "re-renders when the list is rebuilt from raw data.",
          suggestion: "Add `data-key=\"id\"` (or another stable field) on the same element.",
        ))
      end

      def self.emit_reserved_ref_warning(out, name, line, file)
        emit(out, LintWarning.new(
          at: SourceLocation.new(file: file, line: line),
          body: "data-ref #{name.inspect} collides with a Ruby Kernel/Object method. " \
                "`refs.#{name}` will dispatch to the built-in method instead of the ref lookup.",
          suggestion: "Rename the ref (e.g. `#{name}_el`) or access it via `refs[:#{name}]`.",
        ))
      end

      # Writes the warning followed by a blank line so consecutive
      # warnings stay visually separated in stderr output.
      def self.emit(out, warning)
        out.puts(warning.to_s)
        out.puts
      end

      # Closest declared name within SUGGESTION_MAX_DISTANCE, or nil.
      def self.nearest(needle, haystack)
        return nil if haystack.empty?

        candidate, dist = haystack.map { |c| [c, levenshtein(needle, c)] }.min_by { |_, d| d }
        dist <= SUGGESTION_MAX_DISTANCE ? candidate : nil
      end

      # Standard Levenshtein edit distance — insertions, deletions,
      # substitutions. Damerau's transposition adds noise for the
      # typo set we actually see (off-by-one letter swaps), so the
      # plainer metric is enough.
      def self.levenshtein(a, b)
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
