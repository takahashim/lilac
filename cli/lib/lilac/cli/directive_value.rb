# frozen_string_literal: true

module Lilac
  module CLI
    # The right-hand side of a directive that takes a reactive value:
    # `data-text="@count"`, `data-show="it.visible"`, etc. Two kinds
    # exist — `@ivar` (a Signal) and `it` / `it.field` (an iteration
    # item's Data attribute) — and downstream codegen treats them
    # differently:
    #
    #   - Inside a `computed { ... }` block, ivars need `.value` to
    #     subscribe; it_paths pass through verbatim. → `reactive_read`.
    #   - The kwarg form `bind ref, prop: source` calls `source.value`
    #     internally; ivars feed it directly, it_paths need to be
    #     wrapped in `computed { ... }` first. → `bind_source`.
    #
    # Both rules used to live as `value.start_with?("@") ? ... : ...`
    # checks in Codegen. This class moves them onto polymorphic methods
    # of the parsed value so the dispatch happens once at parse time
    # rather than on every emit.
    #
    # `DirectiveValue.parse` returns `Ivar`, `ItPath`, or `nil` for
    # invalid input — callers raise their own build error on nil with
    # an appropriate `attr_name` / source-location context.
    class DirectiveValue
      IVAR    = /\A@[a-zA-Z_]\w*\??\z/.freeze
      IT_PATH = /\Ait(?:\.[a-zA-Z_]\w*\??)?\z/.freeze

      def self.parse(raw)
        s = raw.to_s.strip
        case s
        when IVAR    then Ivar.new(s)
        when IT_PATH then ItPath.new(s)
        end
      end

      attr_reader :raw

      def initialize(raw)
        @raw = raw
      end

      def to_s
        @raw
      end

      # Override Object#inspect so error messages and source-line
      # comments quote the raw form (`"@count"`) instead of dumping
      # `#<DirectiveValue::Ivar:0x...>`.
      def inspect
        @raw.inspect
      end

      def ivar?
        false
      end

      def it_path?
        false
      end
    end

    class DirectiveValue::Ivar < DirectiveValue
      def reactive_read
        "#{@raw}.value"
      end

      def bind_source
        @raw
      end

      def ivar?
        true
      end
    end

    class DirectiveValue::ItPath < DirectiveValue
      def reactive_read
        @raw
      end

      def bind_source
        "computed { #{@raw} }"
      end

      def it_path?
        true
      end
    end
  end
end
