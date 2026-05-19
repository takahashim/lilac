# frozen_string_literal: true

module Lilac
  module CLI
    # The right-hand side of a directive that takes a reactive value.
    # Three kinds exist, all single-identifier (no dot / no expression):
    #
    #   - `@ivar` — host component's Signal/Computed. Inside a
    #     `computed { ... }` block needs `.value` to subscribe; bind ref,
    #     prop: source feeds it directly.
    #   - bare ident — a field of the current iteration item. Only
    #     meaningful inside a `data-each` body (per-row scope). Reads as
    #     `it.<name>` in emitted Ruby (the codegen emits inside the
    #     bind_list block where `it` is the iteration variable).
    #   - `it[.field]` — DEPRECATED. Legacy path form. Codegen still
    #     accepts it (Phase E migration window); runtime emits dev_mode
    #     warning. Will be removed once examples / spec migrate.
    #
    # Downstream codegen treats them differently:
    #
    #   - Inside a `computed { ... }` block, ivars need `.value` to
    #     subscribe; it_path / bare_ident pass through verbatim
    #     (resolved to `it.X` against the per-row `it`). → `reactive_read`.
    #   - The kwarg form `bind ref, prop: source` calls `source.value`
    #     internally; ivars feed it directly, it_path / bare_ident
    #     need wrapping in `computed { ... }`. → `bind_source`.
    #
    # `DirectiveValue.parse` returns `Ivar`, `ItPath`, `BareIdent`, or
    # `nil` for invalid input — callers raise their own build error on
    # nil with an appropriate `attr_name` / source-location context.
    # Match precedence: `@ivar` first, then `it[.path]` (legacy, before
    # bare so `it` itself is captured as ItPath not BareIdent), then
    # bare ident (everything else that looks like a Ruby identifier).
    class DirectiveValue
      IVAR       = /\A@[a-zA-Z_]\w*\??\z/.freeze
      IT_PATH    = /\Ait(?:\.[a-zA-Z_]\w*\??)?\z/.freeze
      BARE_IDENT = /\A[a-zA-Z_]\w*\??\z/.freeze

      def self.parse(raw)
        s = raw.to_s.strip
        case s
        when IVAR       then Ivar.new(s)
        when IT_PATH    then ItPath.new(s)
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

      def it_path?
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

    # Bare identifier referencing a field of the current iteration item.
    # Only emitted inside `data-each` bind_list blocks where `it` is the
    # iteration variable; codegen always rewrites `bare_ident` as
    # `it.<name>` so the runtime path matches the equivalent legacy
    # `it.path` form (the two classes produce identical emitted Ruby
    # — only the source HTML differs).
    class DirectiveValue::BareIdent < DirectiveValue
      def reactive_read
        "it.#{@raw}"
      end

      def bind_source
        "computed { it.#{@raw} }"
      end

      # Raw Signal reference for data-bind. The bind_list block exposes
      # `it`, so `it.title` resolves at runtime to the per-row field
      # value — which must itself be a writable Signal for bind_input
      # to wire correctly (the runtime asserts this; build-time can't).
      def signal_ref
        "it.#{@raw}"
      end

      def bare_ident?
        true
      end
    end
  end
end
