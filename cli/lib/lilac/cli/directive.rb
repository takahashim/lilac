# frozen_string_literal: true

require_relative "source_location"

module Lilac
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
    # `"increment"` / `"{ active: @s }"`). Grammar validation happens
    # per-directive at codegen time; TemplateAST only collects the raw
    # string.
    #
    # `ref_id` is the synthetic or explicit ref name assigned by
    # `TemplateAST` so codegen can address the element via
    # `refs.<ref_id>` (or `t.refs.<ref_id>` inside a data-each block).
    #
    # `line` is the source line in the template body (1-based,
    # Nokogiri's `node.line`), used for error reporting.
    #
    # `element_tag` is the HTML element name (e.g. "div", "button"),
    # consumed by DirectiveCompatibility to enforce applicability rules
    # (e.g. `data-value` requires a form control).
    # `scope_id` is the `ref_id` of the enclosing `data-each` element,
    # or `nil` for directives at the component's top level. Codegen
    # uses it to route the directive into either `bind_template_hook`
    # (top-level) or `bind_template_hook__each_<ref_id>` (iteration
    # body), and to address refs as `refs.X` vs `t.refs.X`.
    #
    # `element_attrs` is the snapshot of all HTML attributes on the
    # source element, keyed by lowercase name. Shared by reference
    # across every Directive on the same element so the cost is one
    # Hash per element rather than per directive. Used by
    # DirectiveCompatibility for checks that need attributes beyond
    # the tag name (e.g. `data-value` requires that an `<input>`'s
    # `type` be text-style).
    Directive = Struct.new(
      :kind,
      :name,
      :value,
      :ref_id,
      :line,
      :element_tag,
      :scope_id,
      :element_attrs,
      keyword_init: true,
    ) do
      # Pair the directive's line with the source file (which the
      # Directive itself doesn't carry) for use in BuildError /
      # LintWarning `at:` kwargs. Saves callers from writing
      # `SourceLocation.new(file: f, line: directive.line)` over and over.
      def source_location(file)
        SourceLocation.new(file: file, line: line)
      end
    end
  end
end
