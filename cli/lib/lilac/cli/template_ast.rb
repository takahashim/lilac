# frozen_string_literal: true

require "nokogiri"
require_relative "build_error"
require_relative "directive"

module Lilac
  module CLI
    # Parses a template body HTML fragment with Nokogiri, walks the
    # element tree, and:
    #
    #   1. Collects every `data-*` directive into a flat list of
    #      `Directive` records (in document order).
    #   2. Assigns a synthetic `data-ref="llcN"` to any element bearing
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
      # Subclass of BuildError so callers can `rescue BuildError` to
      # catch every build-time failure uniformly, regardless of source.
      class Error < BuildError; end

      # One iteration body extracted from a `data-each` element. The
      # Builder later turns each entry into a
      # `<template data-template="llc-each-<component>-<ref>">` injected
      # before `</body>`, which the runtime `bind_list ..., template: ...`
      # clones per iteration item.
      SyntheticBody = Struct.new(:ref_id, :html, keyword_init: true)

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
        # Stack of `{ ref_name => first-declared line }` Hashes. One
        # entry per active ref-scope (top-level, plus one per `data-each`
        # and `data-component` element encountered while walking). New
        # scopes are pushed as `walk` descends and popped on return so
        # duplicate detection respects scope boundaries.
        ref_scopes = [{}]

        walk(fragment, directives, refs_map, [], ref_scopes, synthetic_templates)

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
      # `ref_scopes` is a separate stack tracking the `data-ref`
      # namespace per scope. `data-each` AND `data-component` both open
      # a fresh ref scope (per spec): iteration bodies get a clean ref
      # set per-item at runtime, and a nested component subtree is
      # owned by a different runtime component instance so its refs
      # don't collide with the parent's. The directive `scope_stack`
      # is unaffected by `data-component` — its body's directives still
      # belong to the parent component's bind_template_hook.
      #
      # `synthetic_templates` accumulates extracted iteration bodies in
      # post-order: when we leave a `data-each` element, its children's
      # serialized HTML is captured and the children are unlinked from
      # the main fragment. Post-order guarantees that nested iterations
      # have already been extracted (with their children also cleared)
      # before the outer extraction snapshots its body.
      def walk(node, directives, refs_map, scope_stack, ref_scopes, synthetic_templates)
        # `to_a` so the iteration is stable even when `unlink` mutates
        # the parent's child list during the extraction step below.
        node.element_children.to_a.each do |elem|
          element_directives = extract_directives(elem)
          has_each = element_directives.any? { |k, _, _| k == :each }
          has_component = element_directives.any? { |k, _, _| k == :component }
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
            ref_id = assign_or_reuse_ref(elem, ref_scopes.last)
            # Snapshot all attributes once per element and share the
            # Hash across this element's directives — cheaper than
            # re-walking the Nokogiri attr set per directive.
            attrs = element_attrs_snapshot(elem)
            element_directives.each do |kind, name, attr_value|
              directives << Directive.new(
                kind: kind,
                name: name,
                value: attr_value,
                ref_id: ref_id,
                line: elem.line,
                element_tag: elem.name,
                scope_id: scope_stack.last,
                element_attrs: attrs,
              )
            end
            refs_map[ref_id] ||= { tag: elem.name, line: elem.line }
          elsif (explicit = elem["data-ref"]) && !explicit.empty?
            # Ref declared on an element without any other directive
            # (e.g. `<input data-ref="email">` used only by user-side
            # `refs.email`). Still register so duplicates trip the
            # check, but don't allocate a synthetic / Directive record.
            register_ref!(explicit, elem.line, ref_scopes.last)
          end

          child_ref_scopes = (has_each || has_component) ? ref_scopes + [{}] : ref_scopes

          if has_each
            inner_scope = scope_stack + [ref_id]
            walk(elem, directives, refs_map, inner_scope, child_ref_scopes, synthetic_templates)
            extract_each_body(elem, ref_id, synthetic_templates)
          else
            walk(elem, directives, refs_map, scope_stack, child_ref_scopes, synthetic_templates)
          end
        end
      end

      # Capture the data-each element's body HTML (text + element
      # children) into a synthetic template entry, then strip the body
      # from the main fragment so the dist HTML renders an empty
      # container that bind_list populates per item at runtime.
      def extract_each_body(elem, ref_id, synthetic_templates)
        body_html = elem.children.map(&:to_html).join
        synthetic_templates << SyntheticBody.new(ref_id: ref_id, html: body_html)
        elem.children.unlink
      end

      # HTML attribute names are case-insensitive — normalise to
      # lowercase keys so lookups like `attrs["type"]` work regardless
      # of how the user typed the attribute name in the source.
      def element_attrs_snapshot(elem)
        elem.attributes.each_with_object({}) do |(name, attr), out|
          out[name.downcase] = attr.value
        end.freeze
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

      # If the element already has an explicit `data-ref`, reuse it
      # (so user-chosen refs remain stable across rebuilds) but
      # register it so a duplicate in the same scope raises. Otherwise
      # allocate a fresh synthetic name, skipping any candidate that
      # the user already used at the same scope level.
      def assign_or_reuse_ref(elem, current_ref_scope)
        existing = elem["data-ref"]
        if existing && !existing.empty?
          register_ref!(existing, elem.line, current_ref_scope)
          return existing
        end

        # Auto-assign, skipping refs already used in this scope. The
        # counter is monotonic per parse so we won't loop forever; the
        # skip just handles `<div data-ref="llc3">` collisions with our
        # synthetic llc3.
        loop do
          candidate = "llc#{@ref_counter}"
          @ref_counter += 1
          next if current_ref_scope.key?(candidate)

          current_ref_scope[candidate] = elem.line
          elem["data-ref"] = candidate
          return candidate
        end
      end

      def register_ref!(ref, line, current_ref_scope)
        previous = current_ref_scope[ref]
        if previous
          raise Error.new(
            "Duplicate data-ref #{ref.inspect} — already declared at line #{previous} in the same template scope.",
            at: SourceLocation.new(file: source_file, line: line),
            suggestion: "Rename one of them; data-ref names must be unique within a top-level / data-each / data-component scope.",
          )
        end
        current_ref_scope[ref] = line
      end

      def source_file
        @source_path ? File.basename(@source_path) : "(template)"
      end
    end
  end
end
