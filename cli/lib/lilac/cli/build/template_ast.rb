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
    #      `Directive` records (in document order) for the lint layer.
    #   2. Assigns a synthetic `data-ref="lilN"` to any element bearing
    #      a binding directive but no explicit `data-ref`, so the
    #      runtime scanner can resolve it positionally at mount.
    #   3. Builds `refs_map` keyed by ref name, recording each ref's
    #      source line for duplicate / reserved-name lint checks.
    #
    # SFC's regex-based template extraction (`SFC.parse`) preserves the
    # template body byte-for-byte. TemplateAST does NOT preserve byte
    # equality on the way out — Nokogiri normalizes quoting and
    # boolean attribute serialization. The HTML returned by `parse` is
    # round-tripped through Nokogiri::HTML5.
    #
    # Directive values are NOT validated against the value grammar here
    # — directive attributes are left in the output HTML so the runtime
    # scanner sees `data-component` / `data-ref` and the directives it
    # binds at mount time.
    class TemplateAST
      # Subclass of BuildError so callers can `rescue BuildError` to
      # catch every build-time failure uniformly, regardless of source.
      class Error < BuildError; end

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
        # Form directives (mruby-lilac-form gem). Collected so scope
        # validation / lint can see them; the runtime form scanner wires
        # the actual behavior at mount (resolves scope via ancestor walk).
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
      end

      # Immutable per-frame walk state: the stacks that get pushed/popped
      # as the walker descends/ascends. Bundled so `walk` doesn't have to
      # thread individual args through recursion (the accumulators —
      # directives / refs_map — are mutated in place and stay separate).
      class WalkScopes
        # each_scope: ref_ids of currently-open `data-each` elements;
        #             children's directives carry `scope_id = each_scope.last`
        # ref_scopes: Stack<{ ref_name => line }> for duplicate ref detection
        #             per `data-each` / `data-component` scope
        attr_reader :each_scope, :ref_scopes

        def initialize(each_scope: [], ref_scopes: [{}])
          @each_scope = each_scope
          @ref_scopes = ref_scopes
        end

        # Push helpers return a NEW WalkScopes — frames are immutable so
        # the recursive call doesn't accidentally mutate the parent's stack.
        def push_each(ref_id)
          self.class.new(each_scope: @each_scope + [ref_id], ref_scopes: @ref_scopes)
        end

        def push_ref_scope
          self.class.new(each_scope: @each_scope, ref_scopes: @ref_scopes + [{}])
        end

        def current_ref_scope
          @ref_scopes.last
        end

        def current_each_ref
          @each_scope.last
        end
      end

      def parse
        fragment = Nokogiri::HTML5.fragment(@body_html)
        directives = []
        refs_map = {}
        # `at_root: true` for the outermost walk — when the first
        # element child of the fragment carries `data-component`, it's
        # the component's own root (this AST run IS that component),
        # so its directives + body belong to this component. Any deeper
        # `data-component` element is a different component; we treat
        # those subtrees opaquely so their directives don't leak into
        # the current component's scope.
        walk(fragment, directives, refs_map, WalkScopes.new, at_root: true)

        Result.new(
          html: fragment.to_html,
          directives: directives,
          refs_map: refs_map,
        )
      end

      private

      # `scopes` is a WalkScopes carrying two immutable stacks:
      #   - each_scope: ref_ids of currently-open `data-each` elements
      #     (children carry `scope_id` pointing at the enclosing iteration).
      #   - ref_scopes: per-scope `data-ref` namespace for duplicate detection.
      #     `data-each` AND `data-component` both open a fresh ref scope —
      #     iteration bodies and nested component subtrees each get clean
      #     ref sets. The directive `each_scope` is unaffected by
      #     `data-component` (its body's directives still belong to the
      #     parent component's scope).
      def walk(node, directives, refs_map, scopes, at_root: false)
        node.element_children.to_a.each do |elem|
          element_directives = collect_directives_with_synthesis(elem)
          has_each = element_directives.any? { |k, _, _| k == :each }
          has_component = element_directives.any? { |k, _, _| k == :component }

          # Nested `data-component` (not the parse's outermost element)
          # is a different component, whose directives + body are
          # handled by its OWN AST run. Skip the entire subtree —
          # don't record directives, don't recurse — so the parent's
          # bindings don't double-cover what the nested component will
          # already wire at mount.
          if has_component && !at_root
            next
          end

          # A bare `data-component` element needs no ref_id (the runtime
          # mounts via the data-component attribute), so we skip the
          # Directive record entirely to keep the dist HTML byte-identical
          # and the linter input clean. The :component record only matters
          # when it coexists with another directive (e.g. `data-each`)
          # so Lilac::Directives::Lints can flag the collision.
          has_real_directive = element_directives.any? { |k, _, _| k != :component }
          ref_id = nil

          if has_real_directive
            ref_id = assign_or_reuse_ref(elem, scopes.current_ref_scope)
            element_directives.each do |kind, name, attr_value|
              directives << Directive.new(
                kind: kind,
                name: name,
                value: attr_value,
                ref_id: ref_id,
                line: elem.line,
                element_tag: elem.name,
                scope_id: scopes.current_each_ref,
              )
            end
            refs_map[ref_id] ||= elem.line
          elsif (explicit = elem["data-ref"]) && !explicit.empty?
            # Ref declared on an element without any other directive
            # (e.g. `<input data-ref="email">` used only by user-side
            # `refs.email`). Still register so duplicates trip the
            # check, but don't allocate a synthetic / Directive record.
            unless scopes.current_ref_scope.key?(explicit)
              register_ref!(explicit, elem.line, scopes.current_ref_scope)
            end
          end

          child_scopes = scopes
          # `has_component` only pushes a fresh ref scope for NESTED
          # data-component elements — and we already `next` on those
          # above, so we never reach this branch for them. The root
          # data-component shares its ref scope with this AST run.
          child_scopes = child_scopes.push_ref_scope if has_each

          if has_each
            # scanner-canonical: keep the data-each row IN-PLACE. The
            # runtime scanner's `dispatch_each` snapshots the live
            # innerHTML, empties the container, and clones per item — so
            # the builder must NOT extract the row. We still recurse to
            # collect directives for lint scoping.
            walk(elem, directives, refs_map, child_scopes.push_each(ref_id))
          else
            walk(elem, directives, refs_map, child_scopes)
          end
        end
      end

      # Returns Array<[kind, name, value]> for every directive on `elem`.
      # `name` is nil for non-X-family directives.
      def extract_directives(elem)
        result = []
        elem.attributes.each do |attr_name, attr|
          match_row = DIRECTIVE_PATTERNS.find { |pattern, _, _| pattern.match(attr_name) }
          next unless match_row

          pattern, kind, captures_name = match_row
          match = pattern.match(attr_name)
          name = captures_name ? match[1] : nil
          result << [kind, name, attr.value]
        end
        result
      end

      # Wraps `extract_directives` to inject a synthetic `:form` directive
      # for bare `<form>` elements (no data-form attr), so the lint layer
      # sees the form even when the author didn't name a scope. Keeping
      # this in one named helper makes the "directives can include things
      # not in the HTML" surprise explicit rather than buried in `walk`.
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
      # allocate a fresh synthetic name based on the scope's current
      # size — `refs.lilN` is resolved positionally at runtime, so the
      # name doesn't need to be written back to the DOM (decisions §19).
      def assign_or_reuse_ref(elem, current_ref_scope)
        existing = elem["data-ref"]
        if existing && !existing.empty?
          # register_ref! enforces the `lilN`-namespace reservation +
          # in-scope uniqueness.
          register_ref!(existing, elem.line, current_ref_scope)
          return existing
        end

        # Per-scope counter — synthetic refs are positional indices
        # (0-based) within the current data-component / data-each scope.
        # The runtime walks the same DFS order and maps `lilN` → N-th
        # directive-bearing element. NO DOM mutation: the dist HTML
        # carries no synthetic `data-ref` attributes for normal
        # directive elements (decisions §19).
        counter = current_ref_scope.size
        loop do
          candidate = "lil#{counter}"
          counter += 1
          next if current_ref_scope.key?(candidate)

          current_ref_scope[candidate] = elem.line
          return candidate
        end
      end

      def register_ref!(ref, line, current_ref_scope)
        # `lilN` is reserved for runtime positional ref slots — see ADR-0019.
        if ref.match?(/^lil\d+$/)
          raise Error.new(
            "data-ref=#{ref.inspect}: the `lilN` namespace is reserved for runtime-internal directive slots.",
            at: SourceLocation.new(file: source_file, line: line),
            suggestion: "Use a domain name like `email` / `list` instead.",
          )
        end
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
