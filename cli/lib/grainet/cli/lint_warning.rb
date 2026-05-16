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
    class LintWarning
      def initialize(file:, line:, body:, declared_label: nil, declared: [], suggestion: nil)
        @file = file
        @line = line
        @body = body
        @declared_label = declared_label
        @declared = declared
        @suggestion = suggestion
      end

      def to_s
        parts = ["grainet: lint warning in #{@file}:#{@line}", "  #{@body}"]
        parts << "  #{@declared_label}: #{@declared.join(', ')}." if @declared_label && !@declared.empty?
        parts << "  Did you mean: #{@suggestion}?" if @suggestion
        parts.join("\n")
      end
    end
  end
end
