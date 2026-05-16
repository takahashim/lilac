# frozen_string_literal: true

require_relative "script_scanner"
require_relative "hash_literal_parser"
require_relative "lint_warning"

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

      def self.lint(script_text:, directives:, component_name:, file:, out: $stderr)
        scan = ScriptScanner.scan(script_text)
        warnings = 0

        directives.each do |directive|
          ivars_in_directive(directive).each do |ivar|
            next if scan.declares_signal?(ivar)
            # Soft fallback: any `@x = ...` in the script counts as
            # "user is plausibly initializing this via a helper", so we
            # don't warn even though the RHS isn't a `signal(...)` call.
            # Cost: a genuinely non-signal ivar (e.g. `@plain = "hi"`)
            # used in `data-text` won't be flagged here — it fails at
            # runtime with a clear NoMethodError on `.value`.
            next if scan.assigns_ivar?(ivar)

            emit_signal_warning(out, directive, ivar, scan.signals, component_name, file)
            warnings += 1
          end
          method = method_in_directive(directive)
          next unless method && !scan.declares_method?(method)

          emit_method_warning(out, directive, method, scan.methods, component_name, file)
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

      def self.emit_signal_warning(out, directive, ivar, declared, component_name, file)
        emit(out, LintWarning.new(
          at: directive.source_location(file),
          body: "Signal #{ivar} is not declared via signal/computed/resource/persistent_signal " \
                "in #{component_name}. Possible typo or dynamic declaration.",
          declared_label: "Declared signals", declared: declared,
          suggestion: nearest(ivar, declared),
        ))
      end

      def self.emit_method_warning(out, directive, method, declared, component_name, file)
        emit(out, LintWarning.new(
          at: directive.source_location(file),
          body: "Method `#{method}` (referenced by data-on-#{directive.name}) is not defined " \
                "in #{component_name}. Possible typo or external delegation.",
          declared_label: "Declared methods", declared: declared,
          suggestion: nearest(method, declared),
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
