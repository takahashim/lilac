# frozen_string_literal: true

module Lilac
  module CLI
    # Common base + formatter for build-time errors. Wraps a structured
    # message into the multi-line shape:
    #
    #   lilac: build error in <file>:<line>
    #     <snippet>          # optional
    #     <message body>
    #     <suggestion>       # optional
    #
    # The bare-string form (`raise BuildError, "..."`) is supported so
    # callers that don't have a location on hand can still raise, but
    # the formatted shape only kicks in when `at:` is provided.
    #
    # Subclassed by `Codegen::Error` and `Lilac::Directives::Compat::Error`
    # so existing `assert_raises(Codegen::Error)` calls keep matching.
    class BuildError < StandardError
      attr_reader :at, :snippet, :suggestion

      def initialize(message = nil, at: nil, snippet: nil, suggestion: nil)
        @at = at
        @snippet = snippet
        @suggestion = suggestion
        @body = message
        super(format)
      end

      private

      # Two paths: structured (location known → spec header + indented
      # body) vs bare (no location → return body verbatim, mostly used
      # by code paths that have no source coordinates).
      def format
        return @body unless @at

        parts = ["lilac: build error in #{@at}"]
        parts << "  #{@snippet}" if @snippet
        # Indent each body line so multi-line messages stay aligned.
        if @body
          @body.to_s.each_line do |l|
            parts << "  #{l.chomp}"
          end
        end
        parts << "  #{@suggestion}" if @suggestion
        parts.join("\n")
      end
    end
  end
end
