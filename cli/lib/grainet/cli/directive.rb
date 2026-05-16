# frozen_string_literal: true

module Grainet
  module CLI
    # A single `data-*` directive occurrence on a template element.
    #
    # `kind` is the directive family symbol (e.g. `:text`, `:on`, `:attr`,
    # `:each`). For X-family directives (`data-on-X`, `data-attr-X`,
    # `data-arg-X`, `data-css-X`), `name` carries the X part as it appears in
    # the source (kebab-case, e.g. "click" / "background-color"). For
    # non-X-family directives `name` is `nil`.
    #
    # `value` is the raw attribute value string (e.g. `"@count"` /
    # `"increment"` / `"{ active: @s }"`). Parsing the value against the
    # spec grammar (Section 3) happens in later phases; Phase A1 only
    # collects the raw string.
    #
    # `ref_id` is the synthetic or explicit ref name assigned by
    # `TemplateAST` so codegen can address the element via
    # `refs.<ref_id>` (or `t.refs.<ref_id>` inside a data-each block).
    #
    # `line` is the source line in the template body (1-based,
    # Nokogiri's `node.line`), used for error reporting.
    #
    # `element_tag` is the HTML element name (e.g. "div", "button") used
    # by later phases to enforce applicability rules from spec Section 9
    # (e.g. `data-value` requires a form control).
    # `scope_id` is the `ref_id` of the enclosing `data-each` element,
    # or `nil` for directives at the component's top level. Codegen
    # uses it to route the directive into either `bind_template_hook`
    # (top-level) or `bind_template_hook__each_<ref_id>` (iteration
    # body), and to address refs as `refs.X` vs `t.refs.X`.
    Directive = Struct.new(
      :kind,
      :name,
      :value,
      :ref_id,
      :line,
      :element_tag,
      :scope_id,
      keyword_init: true,
    )
  end
end
