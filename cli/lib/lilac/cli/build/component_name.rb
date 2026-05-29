# frozen_string_literal: true

module Lilac
  module CLI
    # Value object for a `.lil` component's kebab-case name. Holds the
    # raw string and exposes the derived forms the build pipeline
    # needs:
    #
    #   name = ComponentName.new("admin--user-card")
    #   name.ruby_class                 # => "Admin::UserCard"
    #   name.to_s                       # => "admin--user-card"
    #
    # `--` separates namespace segments, `-` separates words within a
    # segment. Empty segments (leading/trailing `--`, double `-` between
    # words) raise at construction so misnamed files fail loudly rather
    # than emitting `::Foo` / `Foo::` downstream.
    class ComponentName
      attr_reader :kebab

      def initialize(kebab)
        @kebab = kebab.to_s
        @ruby_class = build_ruby_class
      end

      def ruby_class
        @ruby_class
      end

      def to_s
        @kebab
      end

      def ==(other)
        other.is_a?(ComponentName) && other.kebab == @kebab
      end
      alias_method :eql?, :==

      def hash
        @kebab.hash
      end

      private

      def build_ruby_class
        @kebab.split("--", -1).map { |segment|
          raise ArgumentError, "Invalid component name: #{@kebab.inspect} (empty namespace segment)" if segment.empty?

          segment.split("-").map { |word|
            raise ArgumentError, "Invalid component name: #{@kebab.inspect} (empty word segment)" if word.empty?

            word[0].upcase + (word[1..] || "")
          }.join
        }.join("::")
      end
    end
  end
end
