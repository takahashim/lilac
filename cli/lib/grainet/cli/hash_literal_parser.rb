# frozen_string_literal: true

module Grainet
  module CLI
    # Parser for the `data-class` hash literal grammar (spec Section 6.4).
    # Recognises Ruby Hash-literal style:
    #
    #   { active: @is_active, 'btn-primary': @primary, "hover:bg-blue": @h }
    #
    # Returns Array<[key_string, value_string]> in source order. Keys are
    # returned as plain strings (quotes stripped); values are the raw
    # text between `:` and the next `,` / `}`, leaving value-grammar
    # validation (ivar / it_path) to the caller (`Codegen.emit_class`).
    #
    # Why a hand-rolled parser and not e.g. JSON.parse: quoted keys may
    # contain `:` (Tailwind variants like `'hover:bg-blue-500'`), so a
    # naive split-on-colon breaks. The grammar is also stricter than
    # JSON (forbids `;`, control chars, whitespace inside keys) and
    # looser elsewhere (bare Ruby idents as keys, no string quoting on
    # values).
    class HashLiteralParser
      class Error < StandardError; end

      BARE_KEY_RE     = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/
      BARE_KEY_CHAR   = /[a-zA-Z0-9_]/
      # Per spec 6.4: quoted-key body forbids whitespace, control chars
      # (\x00-\x1F + \x7F), `;`, and any quote character.
      QUOTED_CHAR_RE  = /\A[^\s\\'";\x00-\x1F\x7F]+\z/

      def self.parse(source)
        new(source).parse
      end

      def initialize(source)
        @src = source.to_s
        @pos = 0
      end

      def parse
        skip_ws
        expect("{")
        skip_ws
        pairs = []
        unless peek == "}"
          pairs << parse_pair
          loop do
            skip_ws
            break unless peek == ","

            advance
            skip_ws
            pairs << parse_pair
          end
        end
        skip_ws
        expect("}")
        skip_ws
        if @pos < @src.length
          raise Error, "unexpected trailing content: #{@src[@pos..].inspect}"
        end

        pairs
      end

      private

      def parse_pair
        skip_ws
        key = parse_key
        skip_ws
        expect(":")
        skip_ws
        value = parse_value
        [key, value]
      end

      def parse_key
        case peek
        when "'" then parse_quoted("'")
        when '"' then parse_quoted('"')
        else parse_bare_ident
        end
      end

      def parse_quoted(quote)
        advance
        start = @pos
        @pos += 1 while @pos < @src.length && @src[@pos] != quote
        raise Error, "unterminated #{quote} string" if @pos >= @src.length

        body = @src[start...@pos]
        advance
        unless QUOTED_CHAR_RE.match?(body)
          raise Error,
                "invalid character(s) in quoted key #{body.inspect} " \
                "(whitespace, control chars, `;`, and quotes are forbidden)"
        end
        body
      end

      def parse_bare_ident
        start = @pos
        @pos += 1 while @pos < @src.length && BARE_KEY_CHAR.match?(@src[@pos])
        body = @src[start...@pos]
        raise Error, "expected hash key at position #{start}, got #{peek.inspect}" if body.empty?
        unless BARE_KEY_RE.match?(body)
          raise Error,
                "bare hash key #{body.inspect} is not a Ruby identifier " \
                "(use quoted form for kebab / special chars)"
        end

        body
      end

      # Values are ivar (`@x`) / it_path (`it.x`) — neither contains the
      # hash delimiters `,` / `}` nor whitespace, so we stop at the first
      # whitespace or delimiter. ValueGrammar validation happens at
      # codegen so the raw substring is returned verbatim here.
      def parse_value
        start = @pos
        until @pos >= @src.length
          ch = @src[@pos]
          break if ch == "," || ch == "}" || ch.match?(/\s/)

          @pos += 1
        end
        raise Error, "expected value, got #{peek.inspect} at #{start}" if @pos == start

        @src[start...@pos]
      end

      def skip_ws
        @pos += 1 while @pos < @src.length && @src[@pos].match?(/\s/)
      end

      def peek
        @src[@pos]
      end

      def advance
        c = @src[@pos]
        @pos += 1
        c
      end

      def expect(ch)
        actual = @src[@pos]
        if actual != ch
          raise Error, "expected #{ch.inspect}, got #{actual.inspect} at position #{@pos}"
        end

        @pos += 1
      end
    end
  end
end
