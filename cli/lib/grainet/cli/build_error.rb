# frozen_string_literal: true

module Grainet
  module CLI
    # Common base + formatter for build-time errors. Wraps a structured
    # message into the multi-line shape:
    #
    #   grainet: build error in <file>:<line>
    #     <snippet>          # optional
    #     <message body>
    #     <suggestion>       # optional
    #
    # The bare-string form (`raise BuildError, "..."`) is supported so
    # callers that don't have a file/line on hand can still raise, but
    # the formatted shape only kicks in when `file:` and `line:` are
    # provided.
    #
    # Subclassed by `Codegen::Error` and `DirectiveCompatibility::Error`
    # so existing `assert_raises(Codegen::Error)` calls keep matching.
    class BuildError < StandardError
      attr_reader :file, :line, :snippet, :suggestion

      def initialize(message = nil, file: nil, line: nil, snippet: nil, suggestion: nil)
        @file = file
        @line = line
        @snippet = snippet
        @suggestion = suggestion
        @body = message
        super(format)
      end

      private

      # Two paths: structured (file+line known → spec header + indented
      # body) vs bare (no file+line → return body verbatim, mostly used
      # by code paths that haven't migrated yet or have no location).
      def format
        return @body unless @file && @line

        parts = ["grainet: build error in #{@file}:#{@line}"]
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
