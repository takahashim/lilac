# frozen_string_literal: true

module Grainet
  module CLI
    # Best-effort scanner that extracts declared signals and method
    # names from a `<script type="text/ruby">` body. Not a real Ruby
    # parser: patterns cover the common ~95% of cases (top-level
    # `@ivar = signal(...)` / `def method_name`). Helper-based
    # initialization, conditional declarations, and dynamic eval are
    # accepted false negatives — those simply don't trip warnings.
    module ScriptScanner
      Result = Struct.new(:signals, :methods, :assigned_ivars, keyword_init: true) do
        def declares_signal?(ivar)
          signals.include?(ivar)
        end

        def declares_method?(name)
          methods.include?(name)
        end

        # Soft fallback for the cross-ref linter: any `@x = ...` was
        # written *somewhere* in the script, so the user is plausibly
        # using a helper-style initializer (e.g. `@count = make_counter`)
        # rather than misspelling the ivar. Used to suppress
        # false-positive signal warnings.
        def assigns_ivar?(ivar)
          assigned_ivars.include?(ivar)
        end
      end

      # `@x = signal(...)`, `@x = computed { ... }`,
      # `@x = resource(...)`, `@x = persistent_signal(...)`.
      # `(?<![\w@])` lookbehind keeps `@@x` and `x@y` from matching.
      SIGNAL_DECL = /
        (?<![\w@])
        @(?<name>[a-zA-Z_]\w*)
        \s* = \s*
        (?:signal|computed|resource|persistent_signal)
        \s* [({]
      /x.freeze

      # `def name`, `def name?`. Bang `!` allowed by Ruby but rejected
      # by directive grammar — capture them anyway so the scanner
      # mirrors what the user actually wrote.
      METHOD_DECL = /
        ^\s*
        def \s+
        (?:self\.)?
        (?<name>[a-zA-Z_]\w*[?!]?)
      /x.freeze

      # Any `@x = ...` assignment, regardless of RHS. `(?!=)` rejects
      # `==` comparison so `if @x == 1` doesn't masquerade as
      # assignment. `||=` / `+=` etc. are intentionally not caught
      # — they imply a prior `=` assignment that this pattern will
      # already have picked up.
      IVAR_ASSIGN = /
        (?<![\w@])
        @(?<name>[a-zA-Z_]\w*)
        \s* = (?!=)
      /x.freeze

      def self.scan(script_text)
        cleaned = strip_comment_lines(script_text.to_s)
        signals = cleaned.scan(SIGNAL_DECL).map { |m| "@#{m.first}" }
        methods = cleaned.scan(METHOD_DECL).map(&:first)
        assigned = cleaned.scan(IVAR_ASSIGN).map { |m| "@#{m.first}" }
        Result.new(
          signals: signals.uniq,
          methods: methods.uniq,
          assigned_ivars: assigned.uniq,
        )
      end

      # Skip whole lines that are comments. Inline `#` doesn't matter
      # for signal/method extraction (the patterns anchor on the leading
      # `@` / `def`, which precedes any `#`).
      def self.strip_comment_lines(src)
        src.each_line.reject { |l| l.strip.start_with?("#") }.join
      end
    end
  end
end
