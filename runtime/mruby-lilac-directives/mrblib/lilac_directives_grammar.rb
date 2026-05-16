module Lilac
  module Directives
    # Predicates for the *name-shaped* tokens that appear in directives —
    # event-handler method names, the X parts of `data-attr-X` /
    # `data-css-X`, and the banned-attribute deny-list. Mirrors
    # `Lilac::CLI::ValueGrammar` 1:1 but ported to runtime, relying on
    # mruby-regexp-compat for the Regexp engine.
    #
    # Reactive *values* (`@ivar` / `it.field`) live on `DirectiveValue`
    # so they can carry their kind polymorphically rather than as a
    # string-prefix check.
    #
    # Anchors: mruby-regexp-compat supports `^`/`$` but not `\A`/`\z`.
    # Since directive values are always single-line strings, `^/$` are
    # equivalent here.
    #
    # Module methods are defined via `class << self` instead of
    # `module_function` because mruby's `module_function` doesn't
    # behave like MRI's (see runtime/mruby-lilac/mrblib/html.rb:60).
    module Grammar
      # `?` predicate suffix allowed (used by `@active?` ivars and
      # `it.done?` field reads). Bang `!` is rejected — the regex
      # stops before any trailing `!`.
      METHOD_IDENT = /^[a-zA-Z_][a-zA-Z0-9_]*$/

      # X part of `data-attr-X` / `data-css-X`: kebab-lowercase,
      # letter-first, no `--` prefix (clashes with CSS variable prefix
      # the framework auto-prepends).
      KEBAB_NAME = /^[a-z][a-z0-9-]*$/

      # Inline event handlers (`on*`), `srcdoc` (iframe HTML injection
      # vector), and `style` (use `data-css-X` or `RefElement#set_style`
      # instead) are banned from `data-attr-X`.
      BANNED_ATTR = /^on[a-z]+$|^srcdoc$|^style$/

      class << self
        # `increment` / `add_todo`. Event-handler method names — no `?`
        # suffix so a typoed `save?` is caught at mount time.
        def method_ident?(s)
          !!METHOD_IDENT.match?(s.to_s)
        end

        # `progress` / `theme-color`. Rejects uppercase, digit-start,
        # leading `-` (which would collide with the auto-prepended `--`).
        def kebab_name?(s)
          str = s.to_s
          !!KEBAB_NAME.match?(str) && !str.start_with?("-")
        end

        def banned_attr?(s)
          !!BANNED_ATTR.match?(s.to_s)
        end
      end
    end
  end
end
