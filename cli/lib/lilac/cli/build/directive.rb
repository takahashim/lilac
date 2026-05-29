# frozen_string_literal: true

require_relative "../source_location"

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
    # `"increment"` / `"{ active: @s }"`). TemplateAST only collects the
    # raw string; grammar validation lives in the lint layer.
    #
    # `ref_id` is the synthetic or explicit ref name assigned by
    # `TemplateAST`, used by the lint layer to group directives sharing
    # an element and to detect duplicate `data-ref` declarations.
    #
    # `line` is the source line in the template body (1-based,
    # Nokogiri's `node.line`), used for error reporting.
    #
    # `element_tag` is the HTML element name (e.g. "div", "button"),
    # consumed by Lilac::Directives::Lints to enforce applicability rules.
    #
    # `scope_id` is the `ref_id` of the enclosing `data-each` element,
    # or `nil` for directives at the component's top level. The lint
    # layer uses it to scope duplicate-ref detection per iteration body.
    Directive = Struct.new(
      :kind,
      :name,
      :value,
      :ref_id,
      :line,
      :element_tag,
      :scope_id,
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
