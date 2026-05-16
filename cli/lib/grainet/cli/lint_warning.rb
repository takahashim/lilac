# frozen_string_literal: true

module Grainet
  module CLI
    # Value object for a single cross-reference lint warning. Centralises
    # the multi-line format so all current and future warning kinds
    # (signal-not-declared, method-not-defined, future dead-signal, ...)
    # render identically:
    #
    #   grainet: lint warning in <file>:<line>
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
      def initialize(at:, body:, declared_label: nil, declared: [], suggestion: nil)
        @at = at
        @body = body
        @declared_label = declared_label
        @declared = declared
        @suggestion = suggestion
      end

      def to_s
        parts = ["grainet: lint warning in #{@at}"]
        @body.to_s.each_line { |l| parts << "  #{l.chomp}" }
        parts << "  #{@declared_label}: #{@declared.join(', ')}." if @declared_label && !@declared.empty?
        parts << "  #{@suggestion}" if @suggestion
        parts.join("\n")
      end
    end
  end
end
