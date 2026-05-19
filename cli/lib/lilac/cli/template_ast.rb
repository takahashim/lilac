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
    #   2. Assigns a synthetic `data-ref="lilN"` to any element bearing
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
      # `<template data-template="lil-each-<component>-<ref>">` injected
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
        # data-bind is the form-independent two-way binding directive
        # (Phase E revival/unification of data-value / data-checked).
        # Property auto-selected from element type:
        # <input type=checkbox> → :checked, others → :value.
        # See directive-spec §6.2 for the full grammar; runtime parity
        # lives in runtime/mruby-lilac-directives/.
        [/\Adata-bind\z/,        :bind,        false],
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
        # Form directives (mruby-lilac-form gem). data-form is detected
        # so scope validation can see it; emit_form is a no-op (the
        # runtime resolves scope via ancestor walk). data-field /
        # data-button get full codegen via emit_field / emit_button.
        [/\Adata-form\z/,        :form,        false],
        [/\Adata-field\z/,       :field,       false],
        [/\Adata-button\z/,      :button,      false],
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

      # Element tags treated as form controls by `data-field` (input /
      # textarea / select). Mirrors runtime `Scanner#find_form_control`.
      FORM_CONTROL_TAGS = %w[input textarea select].freeze

      # Immutable per-frame walk state: the three stacks that get
      # pushed/popped as the walker descends/ascends. Bundled so `walk`
      # doesn't have to thread 7 individual args through recursion (the
      # accumulators — directives / refs_map / synthetic_templates — are
      # mutated in place and stay separate).
      class WalkScopes
        # each_scope: ref_ids of currently-open `data-each` elements;
        #             children's directives carry `scope_id = each_scope.last`
        # ref_scopes: Stack<{ ref_name => line }> for duplicate ref detection
        #             per `data-each` / `data-component` scope
        # form_scopes: Stack of form name Symbols opened by `<form>` elements
        attr_reader :each_scope, :ref_scopes, :form_scopes

        def initialize(each_scope: [], ref_scopes: [{}], form_scopes: [])
          @each_scope = each_scope
          @ref_scopes = ref_scopes
          @form_scopes = form_scopes
        end

        # Push helpers return a NEW WalkScopes — frames are immutable so
        # the recursive call doesn't accidentally mutate the parent's stack.
        def push_each(ref_id)
          self.class.new(each_scope: @each_scope + [ref_id],
                         ref_scopes: @ref_scopes, form_scopes: @form_scopes)
        end

        def push_ref_scope
          self.class.new(each_scope: @each_scope,
                         ref_scopes: @ref_scopes + [{}], form_scopes: @form_scopes)
        end

        def push_form(scope_sym)
          self.class.new(each_scope: @each_scope,
                         ref_scopes: @ref_scopes, form_scopes: @form_scopes + [scope_sym])
        end

        def current_ref_scope
          @ref_scopes.last
        end

        def current_each_ref
          @each_scope.last
        end

        def current_form_scope
          @form_scopes.last || :default
        end
      end

      def parse
        fragment = Nokogiri::HTML5.fragment(@body_html)
        directives = []
        refs_map = {}
        synthetic_templates = []
        walk(fragment, directives, refs_map, synthetic_templates, WalkScopes.new)

        Result.new(
          html: fragment.to_html,
          directives: directives,
          refs_map: refs_map,
          synthetic_templates: synthetic_templates,
        )
      end

      private

      # `scopes` is a WalkScopes carrying three immutable stacks:
      #   - each_scope: ref_ids of currently-open `data-each` elements
      #     (children carry `scope_id` pointing at the enclosing iteration).
      #   - ref_scopes: per-scope `data-ref` namespace for duplicate detection.
      #     `data-each` AND `data-component` both open a fresh ref scope —
      #     iteration bodies and nested component subtrees each get clean
      #     ref sets. The directive `each_scope` is unaffected by
      #     `data-component` (its body's directives still belong to the
      #     parent component's bind_template_hook).
      #   - form_scopes: form name Symbols opened by `<form>` elements,
      #     used to resolve `data-field` / `data-button` to their enclosing
      #     form (mirrors runtime `Scanner#resolve_form_for`).
      #
      # `synthetic_templates` accumulates extracted iteration bodies in
      # post-order: when we leave a `data-each` element, its children's
      # serialized HTML is captured and the children are unlinked from
      # the main fragment. Post-order guarantees that nested iterations
      # have already been extracted (with their children also cleared)
      # before the outer extraction snapshots its body.
      def walk(node, directives, refs_map, synthetic_templates, scopes)
        # `to_a` so the iteration is stable even when `unlink` mutates
        # the parent's child list during the extraction step below.
        node.element_children.to_a.each do |elem|
          element_directives = collect_directives_with_synthesis(elem)
          has_each = element_directives.any? { |k, _, _| k == :each }
          has_component = element_directives.any? { |k, _, _| k == :component }
          is_form_elem = elem.name == "form"

          # A bare `data-component` element needs no ref_id (the
          # runtime mounts via the data-component attribute) and
          # produces no codegen, so we skip the Directive record
          # entirely to keep the dist HTML byte-identical and the
          # linter input clean. The :component record only matters
          # when it coexists with another directive (e.g. `data-each`)
          # so Lilac::Directives::Compat can flag the collision.
          has_real_directive = element_directives.any? { |k, _, _| k != :component }
          ref_id = nil

          # Form scope tracking: a <form> element opens a scope; nested
          # data-field / data-button resolve to the innermost form name.
          # Computed here so the per-directive form_scope assignment below
          # sees the new value when looking at this element's own directives.
          current_form_scope =
            if is_form_elem
              raw_form = element_directives.find { |k, _, _| k == :form }&.then { |_, _, v| v }
              (raw_form && !raw_form.empty?) ? raw_form.to_sym : :default
            else
              scopes.current_form_scope
            end

          if has_real_directive
            ref_id = assign_or_reuse_ref(elem, scopes.current_ref_scope)
            # Snapshot all attributes once per element and share the
            # Hash across this element's directives — cheaper than
            # re-walking the Nokogiri attr set per directive.
            attrs = element_attrs_snapshot(elem)
            # For :field directives, locate (and allocate a ref for) the
            # inner form control. When the data-field element is itself
            # the input, the field_input_ref equals the directive's own
            # ref_id.
            field_input_ref =
              if element_directives.any? { |k, _, _| k == :field }
                find_or_allocate_form_control_ref(elem, scopes.current_ref_scope)
              end
            element_directives.each do |kind, name, attr_value|
              directives << Directive.new(
                kind: kind,
                name: name,
                value: attr_value,
                ref_id: ref_id,
                line: elem.line,
                element_tag: elem.name,
                scope_id: scopes.current_each_ref,
                element_attrs: attrs,
                form_scope: (%i[form field button].include?(kind) ? current_form_scope : nil),
                field_input_ref: (kind == :field ? field_input_ref : nil),
              )
            end
            refs_map[ref_id] ||= { tag: elem.name, line: elem.line }
          elsif (explicit = elem["data-ref"]) && !explicit.empty?
            # Ref declared on an element without any other directive
            # (e.g. `<input data-ref="email">` used only by user-side
            # `refs.email`). Still register so duplicates trip the
            # check, but don't allocate a synthetic / Directive record.
            register_ref!(explicit, elem.line, scopes.current_ref_scope)
          end

          child_scopes = scopes
          child_scopes = child_scopes.push_ref_scope if has_each || has_component
          child_scopes = child_scopes.push_form(current_form_scope) if is_form_elem

          if has_each
            walk(elem, directives, refs_map, synthetic_templates, child_scopes.push_each(ref_id))
            extract_each_body(elem, ref_id, synthetic_templates)
          else
            walk(elem, directives, refs_map, synthetic_templates, child_scopes)
          end
        end
      end

      # For a `data-field` element, return the ref_id of the form control
      # it wraps. When the element itself is an input/textarea/select, that
      # ref is its own (already allocated above). When it's a container,
      # find the first nested form control via CSS selector and allocate a
      # synthetic ref (with `data-ref="lilN"` injected on it) so codegen
      # can address it directly.
      def find_or_allocate_form_control_ref(elem, current_ref_scope)
        if FORM_CONTROL_TAGS.include?(elem.name)
          return elem["data-ref"]
        end
        control = elem.css(FORM_CONTROL_TAGS.join(", ")).first
        return nil unless control
        existing = control["data-ref"]
        return existing if existing && !existing.empty?
        # Assign the data-ref attribute but DON'T register in current_ref_scope
        # — the walker will descend into this control and register the ref via
        # the explicit-ref `elsif` branch, which would double-register if we
        # did it here too.
        loop do
          candidate = "lil#{@ref_counter}"
          @ref_counter += 1
          next if current_ref_scope.key?(candidate)
          control["data-ref"] = candidate
          return candidate
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

      # Wraps `extract_directives` to inject a synthetic `:form` directive
      # for bare `<form>` elements (no data-form attr). The empty value
      # "" signals "bare form" — emit_form / scope tracking treat it as
      # `:default`. Keeping this in one named helper makes the
      # "directives can include things not in the HTML" surprise explicit
      # rather than buried in `walk`.
      def collect_directives_with_synthesis(elem)
        directives = extract_directives(elem)
        if elem.name == "form" && directives.none? { |k, _, _| k == :form }
          directives << [:form, nil, ""]
        end
        directives
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
        # skip just handles `<div data-ref="lil3">` collisions with our
        # synthetic lil3.
        loop do
          candidate = "lil#{@ref_counter}"
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
