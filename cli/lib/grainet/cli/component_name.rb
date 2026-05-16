# frozen_string_literal: true

module Grainet
  module CLI
    # Pure transformation between the kebab-case `.gnt` basename and the
    # Ruby class path the runtime's autoregister produces:
    #
    #   "counter"            → "Counter"
    #   "user-profile"       → "UserProfile"
    #   "admin--user-card"   → "Admin::UserCard"
    #
    # `--` separates namespace segments, `-` separates words within a
    # segment. Empty segments (leading/trailing `--`, double `-` between
    # words) raise so misnamed files fail loudly rather than emitting
    # `::Foo` / `Foo::`.
    module ComponentName
      module_function

      def to_ruby_class(name)
        name.to_s.split("--", -1).map { |segment|
          raise ArgumentError, "Invalid component name: #{name.inspect} (empty namespace segment)" if segment.empty?

          segment.split("-").map { |word|
            raise ArgumentError, "Invalid component name: #{name.inspect} (empty word segment)" if word.empty?

            word[0].upcase + (word[1..] || "")
          }.join
        }.join("::")
      end
    end
  end
end
