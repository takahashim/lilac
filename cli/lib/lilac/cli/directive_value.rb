# frozen_string_literal: true

module Lilac
  module CLI
    # The right-hand side of a directive that takes a reactive value.
    # Two kinds exist, both single-identifier (no dot / no expression):
    #
    #   - `@ivar` — host component's Signal/Computed. Inside a
    #     `computed { ... }` block needs `.value` to subscribe; bind ref,
    #     prop: source feeds it directly.
    #   - bare ident — a field of the current iteration item. Only
    #     meaningful inside a `data-each` body (per-row scope). Codegen
    #     emits `Lilac::ItemField.read(it, :<name>)` so Hash items (the
    #     common JSON-decoded shape) work without NoMethodError.
    #
    # Downstream codegen treats them differently:
    #
    #   - Inside a `computed { ... }` block, ivars need `.value` to
    #     subscribe; bare_ident passes through verbatim (resolved against
    #     the per-row `it`). → `reactive_read`.
    #   - The kwarg form `bind ref, prop: source` calls `source.value`
    #     internally; ivars feed it directly, bare_ident needs wrapping
    #     in `computed { ... }`. → `bind_source`.
    #
    # `DirectiveValue.parse` returns `Ivar`, `BareIdent`, or `nil` for
    # invalid input — callers raise their own build error on nil with an
    # appropriate `attr_name` / source-location context. Match
    # precedence: `@ivar` first, then bare ident (everything else that
    # looks like a Ruby identifier).
    class DirectiveValue
      IVAR       = /\A@[a-zA-Z_]\w*\??\z/.freeze
      BARE_IDENT = /\A[a-zA-Z_]\w*\??\z/.freeze

      def self.parse(raw)
        s = raw.to_s.strip
        case s
        when IVAR       then Ivar.new(s)
        when BARE_IDENT then BareIdent.new(s)
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

      def bare_ident?
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

      # Raw Signal reference (no `.value` unwrap). Used by data-bind
      # codegen to pass the writable Signal directly into `bind_input`.
      def signal_ref
        @raw
      end

      def ivar?
        true
      end
    end

    # Bare identifier referencing a field of the current iteration item.
    # Only emitted inside `data-each` bind_list blocks where `it` is the
    # iteration variable; codegen emits `Lilac::ItemField.read(it, :name)`
    # so Hash items (the common JSON-decoded shape) work without
    # NoMethodError.
    class DirectiveValue::BareIdent < DirectiveValue
      def reactive_read
        "Lilac::ItemField.read(it, :#{@raw})"
      end

      def bind_source
        "computed { #{reactive_read} }"
      end

      # Raw Signal reference for data-bind. The bind_list block exposes
      # `it`, so `Lilac::ItemField.read(it, :title)` resolves at runtime
      # to the per-row field value — which must itself be a writable
      # Signal for bind_input to wire correctly (the runtime asserts
      # this; build-time can't).
      def signal_ref
        reactive_read
      end

      def bare_ident?
        true
      end
    end
  end
end
