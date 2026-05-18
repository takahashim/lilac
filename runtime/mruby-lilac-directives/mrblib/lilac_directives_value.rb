module Lilac
  module Directives
    # The right-hand side of a directive that takes a reactive value.
    # Three kinds exist, all single-identifier(no dot / no path / no
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
    #   - `it[.field]`  — DEPRECATED. Legacy path form, accepted for
    #                   migration; dev_mode warns once per template
    #                   scan. Will be removed once examples / spec
    #                   doc migrate (proposals doc:
    #                   "`it.path` 全廃 + value-binding bare-ident scope").
    #
    # Mirrors `Lilac::CLI::DirectiveValue` 1:1.
    #
    # `Value.parse` returns `Ivar`, `BareIdent`, `ItPath`, or `nil`
    # for invalid input — callers raise their own error with directive
    # context. Match precedence: `@ivar` first(unambiguous prefix),
    # then `it[.path]`(legacy, before bare so `it` itself is captured
    # as ItPath not BareIdent), then bare ident(everything else that
    # looks like a Ruby identifier).
    class Value
      # Anchors use `^`/`$` not `\A`/`\z` — see Grammar for the
      # mruby-regexp-compat compatibility note.
      IVAR       = /^@[a-zA-Z_]\w*\??$/
      IT_PATH    = /^it(?:\.[a-zA-Z_]\w*\??)?$/
      BARE_IDENT = /^[a-zA-Z_]\w*\??$/

      # Tracks raw `it[.X]` strings already warned about in dev_mode so the
      # deprecation message fires once per unique usage, not per scan.
      DEPRECATED_IT_WARNED = {}

      def self.parse(raw)
        s = raw.to_s.strip
        if IVAR.match?(s)
          Ivar.new(s)
        elsif IT_PATH.match?(s)
          # Match before BARE_IDENT so `it` (bare) and `it.x` both go
          # to ItPath for deprecation handling.
          warn_it_path_deprecated(s) if Lilac.dev_mode?
          ItPath.new(s)
        elsif BARE_IDENT.match?(s)
          BareIdent.new(s)
        end
      end

      def self.warn_it_path_deprecated(raw)
        return if DEPRECATED_IT_WARNED[raw]
        DEPRECATED_IT_WARNED[raw] = true
        Lilac.logger.warn(
          "`#{raw}` (it / it.path) in directive value is deprecated; " \
          "use a bare identifier in value-binding directives (e.g. " \
          "`data-text=\"name\"` inside data-each), or remove the " \
          "`data-prop-X=\"it.Y\"` attribute and rely on child `prop :Y` " \
          "auto-fill from the iteration item",
        )
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

      def it_path?
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

    class Value::ItPath < Value
      # `it.title` -> "title"; bare `it` -> nil.
      def field
        idx = @raw.index(".")
        idx ? @raw[(idx + 1)..] : nil
      end

      def it_path?
        true
      end
    end

    # Bare identifier referring to a field of the current iteration item.
    # Outside `data-each` scope (item.nil?), value-binding dispatch
    # silent-skips, matching the existing `it.path` convention.
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
