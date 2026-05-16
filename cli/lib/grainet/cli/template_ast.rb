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
    # Phase A1 scope:
    #
    #   - Detect directives, assign synthetic refs, return Directive list.
    #   - Do NOT validate directive values against the spec grammar yet
    #     (Section 3 validation arrives with the per-directive phases).
    #   - Do NOT strip directive attributes from the output HTML — keeping
    #     them in place lets `data-component`/`data-ref` continue to flow
    #     through to the runtime, and is harmless for the other
    #     directives until codegen actually consumes them.
    class TemplateAST
      Result = Struct.new(:html, :directives, :refs_map, keyword_init: true)

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

        walk(fragment, directives, refs_map)

        Result.new(
          html: fragment.to_html,
          directives: directives,
          refs_map: refs_map,
        )
      end

      private

      def walk(node, directives, refs_map)
        node.element_children.each do |elem|
          element_directives = extract_directives(elem)

          unless element_directives.empty?
            ref_id = ensure_ref_id(elem)
            element_directives.each do |kind, name, attr_value|
              directives << Directive.new(
                kind: kind,
                name: name,
                value: attr_value,
                ref_id: ref_id,
                line: elem.line,
                element_tag: elem.name,
              )
            end
            refs_map[ref_id] ||= { tag: elem.name, line: elem.line }
          end

          walk(elem, directives, refs_map)
        end
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
