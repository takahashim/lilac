# frozen_string_literal: true

module Grainet
  module CLI
    # Validators for directive value strings, derived from spec Appendix A.
    # Each pattern is anchored (\A...\z) on its public predicate so callers
    # always match the whole string.
    #
    # See docs/grainet-directive-spec.md Section 3 (値の文法) and
    # Appendix A (Validator regexp) for the grammar this implements.
    module ValueGrammar
      # The base building block. `?` predicate suffix allowed; bang `!`
      # is rejected at the IDENT level (the regex below stops before any
      # trailing `!`).
      IDENT_INNER          = /[a-zA-Z_][a-zA-Z0-9_]*\??/
      METHOD_IDENT_INNER   = /[a-zA-Z_][a-zA-Z0-9_]*/        # no `?` for event handlers
      REF_IDENT_INNER      = /[a-z_][a-zA-Z0-9_]*/           # ref names: lowercase start
      CLASS_SEGMENT_INNER  = /[A-Z][a-zA-Z0-9_]*/            # one PascalCase segment

      IDENT         = /\A#{IDENT_INNER.source}\z/
      METHOD_IDENT  = /\A#{METHOD_IDENT_INNER.source}\z/
      REF_IDENT     = /\A#{REF_IDENT_INNER.source}\z/
      CLASS_NAME    = /\A#{CLASS_SEGMENT_INNER.source}(?:::#{CLASS_SEGMENT_INNER.source})*\z/

      IVAR          = /\A@#{IDENT_INNER.source}\z/
      IT_PATH       = /\Ait(?:\.#{IDENT_INNER.source})?\z/
      READ_VALUE    = /\A(?:@#{IDENT_INNER.source}|it(?:\.#{IDENT_INNER.source})?)\z/

      module_function

      # `@count` / `@is_negative` / `@valid?`. Bang `!` always rejected.
      def ivar?(s) = IVAR.match?(s)

      # `it` / `it.title` / `it.valid?`. Only one level of `.`; `it.user.name`
      # is rejected so the caller can choose to view-model the value.
      def it_path?(s) = IT_PATH.match?(s)

      # Either an ivar or an it_path — the union spec calls READ_VALUE.
      # Used by `data-text` / `data-unsafe-html` / `data-show` / `data-hide`
      # / `data-attr-X` / `data-css-X` / `data-each`.
      def read_value?(s) = READ_VALUE.match?(s)

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
    end
  end
end
