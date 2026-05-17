module Lilac
  module Directives
    # The right-hand side of a directive that takes a reactive value:
    # `data-text="@count"`, `data-show="it.visible"`, etc. Two kinds
    # exist — `@ivar` (a Signal) and `it` / `it.field` (an iteration
    # item's attribute) — and the runtime evaluator treats them
    # differently:
    #
    #   - `@ivar` resolves via `Evaluator#lookup_ivar` and feeds directly
    #     into `bind ref, prop: signal` (the binder calls `.value`
    #     internally inside an effect).
    #   - `it.field` requires per-iteration evaluation, so it gets
    #     wrapped in a `computed { ... }` block at bind time.
    #
    # Mirrors `Lilac::CLI::DirectiveValue` 1:1.
    #
    # `Value.parse` returns `Ivar`, `ItPath`, or `nil` for invalid
    # input — callers raise their own error with directive context.
    class Value
      # Anchors use `^`/`$` not `\A`/`\z` — see Grammar for the
      # mruby-regexp-compat compatibility note.
      IVAR    = /^@[a-zA-Z_]\w*\??$/
      IT_PATH = /^it(?:\.[a-zA-Z_]\w*\??)?$/

      def self.parse(raw)
        s = raw.to_s.strip
        if IVAR.match?(s)
          Ivar.new(s)
        elsif IT_PATH.match?(s)
          ItPath.new(s)
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

      def it_path?
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
  end
end
