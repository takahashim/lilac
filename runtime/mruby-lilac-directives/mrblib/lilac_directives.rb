module Lilac
  # Runtime interpreter for declarative `data-*` directives.
  #
  # When a Lilac::Component mounts, its default `bind_template_hook`
  # checks for `Lilac::Directives::Scanner` and runs it against the
  # component's root subtree. The scanner walks the DOM, parses
  # directive attributes (`data-text`, `data-on-*`, `data-each`, etc.),
  # and calls the same `bind` / `bind_input` / `bind_list` DSL that
  # CLI-emitted code would call.
  #
  # If a `Lilac::Bindings::<ClassName>` module is included into the
  # component class (as CLI codegen produces), its `bind_template_hook`
  # override runs instead — the runtime scanner is the fallback for
  # components built without the CLI.
  #
  # Submodules:
  #   - `Grammar`      — name-shaped token predicates (method ident, kebab, ...)
  #   - `Value`        — `@ivar` / `it[.field]` / bare ident parsed RHS
  #   - `Evaluator`    — resolves Value against host + iteration item
  #   - `ItemField`    — single-source lookup of `item[name]` (Hash sym → str
  #                      → public_send), shared by Evaluator and PropAutoFill
  #   - `PropAutoFill` — populates child component props from iteration item
  #                      when no explicit `data-prop-X` is given
  #   - `Compat`       — runtime compatibility / element-type checks
  #   - `Scanner`      — DOM walk + per-directive dispatch
  module Directives
  end
end
