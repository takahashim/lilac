# frozen_string_literal: true

module Lilac
  module CLI
    # Value object for a single cross-reference lint warning. Centralises
    # the multi-line format so all current and future warning kinds
    # (signal-not-declared, method-not-defined, future dead-signal, ...)
    # render identically:
    #
    #   lilac: lint warning in <file>:<line>
    #     <body>
    #     <declared_label>: a, b, c.
    #     Did you mean: <suggestion>?
    #
    # `declared` and `suggestion` are optional — when empty/nil the
    # corresponding lines are omitted so single-fact warnings stay
    # compact.
    #
    # `suggestion` is rendered verbatim as an indented bullet — callers
    # add their own framing (`"Did you mean: ..."` / `"Use ..."` /
    # etc.) so the same warning shape carries both typo hints and
    # corrective advice.
    class LintWarning
      # `severity:` is `:warning` (default — non-fatal, build continues)
      # or `:error` (fatal — build fails with non-zero exit code).
      # Errors are reserved for violations that runtime would `raise`
      # (so the build/runtime severity stays aligned).
      def initialize(at:, body:, declared_label: nil, declared: [], suggestion: nil, severity: :warning)
        @at = at
        @body = body
        @declared_label = declared_label
        @declared = declared
        @suggestion = suggestion
        @severity = severity
      end

      attr_reader :severity

      def error?
        @severity == :error
      end

      def to_s
        label = error? ? "lint error" : "lint warning"
        parts = ["lilac: #{label} in #{@at}"]
        @body.to_s.each_line { |l| parts << "  #{l.chomp}" }
        parts << "  #{@declared_label}: #{@declared.join(', ')}." if @declared_label && !@declared.empty?
        parts << "  #{@suggestion}" if @suggestion
        parts.join("\n")
      end
    end
  end
end
