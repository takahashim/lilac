module Lilac
  module Directives
    # Parser for the `data-class` hash literal grammar. Mirrors
    # `Lilac::CLI::HashLiteralParser`:
    #
    #   { active: @is_active, 'btn-primary': @primary, "hover:bg-blue": @h }
    #
    # Returns Array<[key_string, value_string]> in source order. Keys
    # are returned as plain strings (quotes stripped); values are the
    # raw text between `:` and the next `,` / `}`, leaving value-
    # grammar validation (ivar / bare ident) to the caller (Scanner).
    #
    # Quoted keys may contain `:` (Tailwind variants like
    # `'hover:bg-blue-500'`), so a naive split-on-colon would break.
    # The grammar is stricter than JSON (forbids `;`, control chars,
    # whitespace inside keys) and looser elsewhere (bare Ruby idents
    # as keys, no string quoting on values).
    #
    # Per-character checks use char comparisons rather than JS-bridged
    # Regexp.test calls because they run in inner loops; whole-string
    # validates use Regexp.
    class ClassParser
      class Error < StandardError; end

      BARE_KEY = /^[a-zA-Z_][a-zA-Z0-9_]*$/

      # Spec 6.4: quoted-key body forbids whitespace, control chars
      # (\x00-\x1F + \x7F), `;`, and any quote character. Checked via
      # `valid_quoted_body?` (char-walk) instead of a Regexp because
      # mruby-regexp-compat doesn't support `\xHH` hex escapes inside
      # character classes — `[^\s\\'";\x00-\x1F\x7F]` mis-parses as a
      # class containing literal `x`/`0`/etc.

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
        unless valid_quoted_body?(body)
          raise Error,
                "invalid character(s) in quoted key #{body.inspect} " \
                "(whitespace, control chars, `;`, and quotes are forbidden)"
        end
        body
      end

      def parse_bare_ident
        start = @pos
        @pos += 1 while @pos < @src.length && bare_key_char?(@src[@pos])
        body = @src[start...@pos]
        raise Error, "expected hash key at position #{start}, got #{peek.inspect}" if body.empty?
        unless BARE_KEY.match?(body)
          raise Error,
                "bare hash key #{body.inspect} is not a Ruby identifier " \
                "(use quoted form for kebab / special chars)"
        end
        body
      end

      # Values are ivar (`@x`) / bare ident (`x`) — neither contains
      # the hash delimiters `,` / `}` nor whitespace, so stop at the
      # first whitespace or delimiter. Grammar validation happens in
      # the caller (Scanner.dispatch_class via Value.parse).
      def parse_value
        start = @pos
        until @pos >= @src.length
          ch = @src[@pos]
          break if ch == "," || ch == "}" || ws_char?(ch)
          @pos += 1
        end
        raise Error, "expected value, got #{peek.inspect} at #{start}" if @pos == start
        @src[start...@pos]
      end

      def skip_ws
        @pos += 1 while @pos < @src.length && ws_char?(@src[@pos])
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

      # Per-char predicates inlined to avoid a JS-bridged Regexp.test
      # call per character (which would dominate cost in tight loops).

      def ws_char?(c)
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\f" || c == "\v"
      end

      def bare_key_char?(c)
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") ||
          (c >= "0" && c <= "9") || c == "_"
      end

      # Whole-body validator for quoted keys. Rejects empty, any of
      # `\\`, `'`, `"`, `;`, whitespace, control chars (< 0x20 or == 0x7F).
      def valid_quoted_body?(body)
        return false if body.empty?
        body.each_char do |c|
          return false if c == "\\" || c == "'" || c == "\"" || c == ";"
          return false if ws_char?(c)
          code = c.ord
          return false if code < 0x20 || code == 0x7F
        end
        true
      end
    end
  end
end
