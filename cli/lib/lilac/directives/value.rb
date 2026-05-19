module Lilac
  module Directives
    # The right-hand side of a directive that takes a reactive value.
    # Two kinds exist, both single-identifier (no dot / no path / no
    # expression):
    #
    #   - `@ivar`     — a host Signal/Computed. Resolves via
    #                   `Evaluator#lookup_ivar` and feeds into
    #                   `bind ref, prop: signal` directly.
    #   - bare ident  — a field of the current iteration item.
    #                   `Evaluator#read` reads `item[name]` (Hash key
    #                   first, then String fallback, then public_send).
    #                   Only meaningful inside a `data-each` body;
    #                   value-binding dispatch silent-skips when
    #                   `item.nil?` (= scanning the host root).
    #
    # Duplicate pair (build-time / runtime). See decisions §17.
    #
    # `Value.parse` returns `Ivar`, `BareIdent`, or `nil` for invalid
    # input — callers raise their own error with directive context.
    # Match precedence: `@ivar` first (unambiguous prefix), then bare
    # ident (everything else that looks like a Ruby identifier).
    class Value
      # Anchors use `^`/`$` not `\A`/`\z` — see Grammar for the
      # mruby-regexp-compat compatibility note.
      IVAR       = /^@[a-zA-Z_]\w*\??$/
      BARE_IDENT = /^[a-zA-Z_]\w*\??$/

      def self.parse(raw)
        s = raw.to_s.strip
        if IVAR.match?(s)
          Ivar.new(s)
        elsif BARE_IDENT.match?(s)
          BareIdent.new(s)
        end
      end

      attr_reader :raw

      def initialize(raw)
        @raw = raw
      end

      def to_s
        @raw
      end

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

    class Value::Ivar < Value
      # `@count` -> :@count
      def ivar_sym
        @raw.to_sym
      end

      def ivar?
        true
      end
    end

    # Bare identifier referring to a field of the current iteration item.
    # Outside `data-each` scope (item.nil?), value-binding dispatch
    # silent-skips.
    class Value::BareIdent < Value
      def field
        @raw
      end

      def bare_ident?
        true
      end
    end
  end
end
