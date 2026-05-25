# frozen_string_literal: true

module Lilac
  module CLI
    # `(file, line)` pair that appears in every build-time error and
    # lint warning. Kept as one value so error/warning constructors take
    # a single `at:` kwarg instead of two, and so future additions
    # (column, snippet excerpt, end-line for ranges) can be tacked on
    # here without rippling through every raise site.
    SourceLocation = Struct.new(:file, :line, keyword_init: true) do
      def to_s
        "#{file}:#{line}"
      end
    end
  end
end
