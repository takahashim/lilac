# frozen_string_literal: true

module Grainet
  module CLI
    # Predicates for *name-shaped* tokens that appear in directives —
    # event-handler method names, X parts of `data-attr-X` /
    # `data-css-X` / `data-arg-X`, banned attribute names, etc. Each
    # pattern is anchored (\A...\z) on its public predicate so callers
    # always match the whole string.
    #
    # Reactive *values* (`@ivar` / `it.field`) live on `DirectiveValue`
    # so they can carry their kind as polymorphism rather than as a
    # string-prefix check.
    module ValueGrammar
      # `?` predicate suffix allowed; bang `!` is rejected at the
      # IDENT level (the regex stops before any trailing `!`).
      IDENT_INNER          = /[a-zA-Z_][a-zA-Z0-9_]*\??/
      METHOD_IDENT_INNER   = /[a-zA-Z_][a-zA-Z0-9_]*/        # no `?` for event handlers
      REF_IDENT_INNER      = /[a-z_][a-zA-Z0-9_]*/           # ref names: lowercase start
      CLASS_SEGMENT_INNER  = /[A-Z][a-zA-Z0-9_]*/            # one PascalCase segment

      METHOD_IDENT  = /\A#{METHOD_IDENT_INNER.source}\z/
      REF_IDENT     = /\A#{REF_IDENT_INNER.source}\z/
      CLASS_NAME    = /\A#{CLASS_SEGMENT_INNER.source}(?:::#{CLASS_SEGMENT_INNER.source})*\z/

      # X part of `data-attr-X` / `data-css-X` / `data-arg-X`:
      # kebab-lowercase, letter-first. `--` prefix rejected to avoid
      # clashing with the CSS variable `--` prefix the framework prepends.
      KEBAB_NAME    = /\A[a-z][a-z0-9-]*\z/

      # Inline event handlers (`on*`), `srcdoc` (iframe HTML injection
      # vector), and `style` (use `data-css-X` or `RefElement#set_style`
      # instead) are banned from `data-attr-X`.
      BANNED_ATTR   = /\Aon[a-z]+\z|\Asrcdoc\z|\Astyle\z/

      module_function

      # `increment` / `add_todo`. Event-handler method names — no `?`
      # suffix so a typoed `save?` is caught at build time.
      def method_ident?(s) = METHOD_IDENT.match?(s)

      # `Counter` / `Admin::UserCard`. PascalCase + `::` namespace.
      def class_name?(s) = CLASS_NAME.match?(s)

      # `canvas` / `submit_button`. Lowercase-start identifier used for
      # `data-ref="..."` values. Not currently called by the codegen
      # (refs are extracted by TemplateAST and used as-is); exposed for
      # future build-time validation.
      def ref_ident?(s) = REF_IDENT.match?(s)

      # `data-css-Color` (uppercase), `data-css-3d-effect` (digit
      # start), `data-css--theme-color` (double-hyphen prefix) all
      # rejected. KEBAB_NAME's `[a-z][...]*` covers the first two; the
      # explicit `--` check guards against the framework's auto-prepend
      # of `--` for CSS variables producing `----X`.
      def kebab_name?(s) = KEBAB_NAME.match?(s) && !s.start_with?("-")

      def banned_attr?(s) = BANNED_ATTR.match?(s)
    end
  end
end
