# frozen_string_literal: true

# Build-time-only extension to `Lilac::Directives::Grammar`. The
# runtime half (`runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb`)
# doesn't need these — at runtime, class names are resolved via
# `Object.const_get` and ref names are taken verbatim. Codegen needs
# them to validate `data-component` / `data-ref` values before emit.
# The base file `grammar.rb` is the diff-0 duplicate-pair body shared
# with runtime; this file lives only on the build-time side. See
# decisions §17.

module Lilac
  module Directives
    module Grammar
      # Composable INNER fragments — used by build-time validators
      # only. The runtime half doesn't expose these because it never
      # composes the patterns externally.
      IDENT_INNER          = /[a-zA-Z_][a-zA-Z0-9_]*\??/
      METHOD_IDENT_INNER   = /[a-zA-Z_][a-zA-Z0-9_]*/        # no `?` for event handlers
      REF_IDENT_INNER      = /[a-z_][a-zA-Z0-9_]*/           # ref names: lowercase start
      CLASS_SEGMENT_INNER  = /[A-Z][a-zA-Z0-9_]*/            # one PascalCase segment

      REF_IDENT  = /^#{REF_IDENT_INNER.source}$/
      CLASS_NAME = /^#{CLASS_SEGMENT_INNER.source}(?:::#{CLASS_SEGMENT_INNER.source})*$/

      class << self
        # `Counter` / `Admin::UserCard`. PascalCase + `::` namespace.
        def class_name?(s)
          !!CLASS_NAME.match?(s.to_s)
        end

        # `canvas` / `submit_button`. Lowercase-start identifier used
        # for `data-ref="..."` values. Currently exposed for future
        # build-time validation (refs are taken verbatim today).
        def ref_ident?(s)
          !!REF_IDENT.match?(s.to_s)
        end
      end
    end
  end
end
