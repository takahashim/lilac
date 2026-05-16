# frozen_string_literal: true

require "nokogiri"
require_relative "directive"

module Grainet
  module CLI
    # Parses a template body HTML fragment with Nokogiri, walks the
    # element tree, and:
    #
    #   1. Collects every `data-*` directive into a flat list of
    #      `Directive` records (in document order).
    #   2. Assigns a synthetic `data-ref="gN"` to any element bearing
    #      a binding directive but no explicit `data-ref`, so codegen
    #      can address the element by stable name.
    #   3. Builds `refs_map` keyed by ref name, recording the element
    #      tag and original source line for later applicability checks.
    #
    # SFC's regex-based template extraction (`SFC.parse`) preserves the
    # template body byte-for-byte. TemplateAST does NOT preserve byte
    # equality on the way out — Nokogiri normalizes quoting and
    # boolean attribute serialization. The HTML returned by `parse` is
    # round-tripped through Nokogiri::HTML5.
    #
    # Directive values are NOT validated against the value grammar here
    # — that lives in the per-directive Codegen emitters. Directive
    # attributes are left in the output HTML so `data-component` /
    # `data-ref` continue to flow through to the runtime.
    class TemplateAST
      # `synthetic_templates` carries `data-each` iteration bodies
      # extracted out of the main template tree. Each entry is
      # `{ ref_id: "g0", html: "<li>...</li>" }`; the Builder turns
      # them into `<template data-template="gn-each-<component>-<ref>">`
      # elements injected before `</body>`, which the runtime
      # `bind_list ..., template: ...` clones per iteration item.
      Result = Struct.new(:html, :directives, :refs_map, :synthetic_templates, keyword_init: true)

      # Maps an attribute-name regex to its directive kind. Order matters:
      # the more specific X-family patterns (`data-on-X` etc.) must be
      # checked before the simpler ones so that `data-on-click` is
      # classified as `:on` not as an unknown attribute.
      #
      # `class_` trailing underscore avoids shadowing Ruby's reserved
      # `class` keyword in pattern-match contexts; symbol-side only.
      DIRECTIVE_PATTERNS = [
        [/\Adata-text\z/,        :text,        false],
        [/\Adata-unsafe-html\z/, :unsafe_html, false],
        [/\Adata-value\z/,       :value,       false],
        [/\Adata-checked\z/,     :checked,     false],
        [/\Adata-show\z/,        :show,        false],
        [/\Adata-hide\z/,        :hide,        false],
        [/\Adata-each\z/,        :each,        false],
        [/\Adata-key\z/,         :key,         false],
        [/\Adata-class\z/,       :class_,      false],
        # data-component is detected only so collision checks can see
        # it; it has no emit_* of its own (the runtime autoregister
        # reads the HTML attribute directly) and `walk` skips Directive
        # records when it appears alone, to keep the dist HTML and the
        # linter input unchanged for the common case.
        [/\Adata-component\z/,   :component,   false],
        [/\Adata-on-(.+)\z/,     :on,          true],
        [/\Adata-attr-(.+)\z/,   :attr,        true],
        [/\Adata-arg-(.+)\z/,    :arg,         true],
        [/\Adata-css-(.+)\z/,    :css,         true],
      ].freeze

      def initialize(body_html, source_path: nil)
        @body_html = body_html
        @source_path = source_path
        @ref_counter = 0
      end

      def parse
        fragment = Nokogiri::HTML5.fragment(@body_html)
        directives = []
        refs_map = {}
        synthetic_templates = []

        walk(fragment, directives, refs_map, [], synthetic_templates)

        Result.new(
          html: fragment.to_html,
          directives: directives,
          refs_map: refs_map,
          synthetic_templates: synthetic_templates,
        )
      end

      private

      # `scope_stack` holds the ref_ids of currently-open `data-each`
      # elements (outermost first). Children of a `data-each` element are
      # walked with that element's ref_id pushed onto the stack, so their
      # directives carry `scope_id` pointing at the enclosing iteration.
      #
      # `synthetic_templates` accumulates extracted iteration bodies in
      # post-order: when we leave a `data-each` element, its children's
      # serialized HTML is captured and the children are unlinked from
      # the main fragment. Post-order guarantees that nested iterations
      # have already been extracted (with their children also cleared)
      # before the outer extraction snapshots its body.
      def walk(node, directives, refs_map, scope_stack, synthetic_templates)
        # `to_a` so the iteration is stable even when `unlink` mutates
        # the parent's child list during the extraction step below.
        node.element_children.to_a.each do |elem|
          element_directives = extract_directives(elem)
          has_each = element_directives.any? { |k, _, _| k == :each }
          # A bare `data-component` element needs no ref_id (the
          # runtime mounts via the data-component attribute) and
          # produces no codegen, so we skip the Directive record
          # entirely to keep the dist HTML byte-identical and the
          # linter input clean. The :component record only matters
          # when it coexists with another directive (e.g. `data-each`)
          # so DirectiveCompatibility can flag the collision.
          has_real_directive = element_directives.any? { |k, _, _| k != :component }
          ref_id = nil

          if has_real_directive
            ref_id = ensure_ref_id(elem)
            element_directives.each do |kind, name, attr_value|
              directives << Directive.new(
                kind: kind,
                name: name,
                value: attr_value,
                ref_id: ref_id,
                line: elem.line,
                element_tag: elem.name,
                scope_id: scope_stack.last,
              )
            end
            refs_map[ref_id] ||= { tag: elem.name, line: elem.line }
          end

          if has_each
            inner_scope = scope_stack + [ref_id]
            walk(elem, directives, refs_map, inner_scope, synthetic_templates)
            extract_each_body(elem, ref_id, synthetic_templates)
          else
            walk(elem, directives, refs_map, scope_stack, synthetic_templates)
          end
        end
      end

      # Capture the data-each element's body HTML (text + element
      # children) into a synthetic template entry, then strip the body
      # from the main fragment so the dist HTML renders an empty
      # container that bind_list populates per item at runtime.
      def extract_each_body(elem, ref_id, synthetic_templates)
        body_html = elem.children.map(&:to_html).join
        synthetic_templates << { ref_id: ref_id, html: body_html }
        elem.children.unlink
      end

      # Returns Array<[kind, name, value]> for every directive on `elem`.
      # `name` is nil for non-X-family directives.
      def extract_directives(elem)
        result = []
        elem.attributes.each do |attr_name, attr|
          DIRECTIVE_PATTERNS.each do |pattern, kind, captures_name|
            match = pattern.match(attr_name)
            next unless match

            name = captures_name ? match[1] : nil
            result << [kind, name, attr.value]
            break
          end
        end
        result
      end

      # If the element already has an explicit `data-ref`, reuse that name
      # as the ref_id so user-chosen refs remain stable across rebuilds.
      # Otherwise allocate a fresh synthetic name `g0`, `g1`, ...
      def ensure_ref_id(elem)
        existing = elem["data-ref"]
        return existing if existing && !existing.empty?

        ref = "g#{@ref_counter}"
        @ref_counter += 1
        elem["data-ref"] = ref
        ref
      end
    end
  end
end
