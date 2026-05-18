module Lilac
  module Directives
    # Walks the DOM subtree under a Component's root, extracts
    # `data-*` directives from each element, and wires the equivalent
    # `bind` / `bind_input` / event-listener / effect calls that the
    # CLI codegen would have emitted.
    #
    # Boundaries:
    #   - Stops descent at nested `data-component` subtrees (those are
    #     mounted by their own component instance, which runs its own
    #     Scanner).
    #   - Phase 1: refuses to descend into `data-each` elements
    #     (warns instead). Real iteration support arrives in Phase 3.
    #
    # No synthetic `data-ref="lilN"` allocation: the runtime closes
    # over the element's JS::Object directly, wrapping it in a fresh
    # `RefElement` per binding. This sidesteps the codegen's need for
    # a stable name to write into emitted Ruby.
    class Scanner
      # FormWiring owns dispatch_field / dispatch_button / wire_form_submit
      # and helpers. Included (not delegated) so methods share @host /
      # @default_form_seen / @input_form_attr_warned / wrap_ref.
      include FormWiring

      DIRECTIVE_PATTERNS = [
        [/\Adata-text\z/,        :text,        false],
        [/\Adata-unsafe-html\z/, :unsafe_html, false],
        # data-bind is the form-independent two-way binding directive
        # (revived & unified successor of the Phase-D-removed data-value
        # / data-checked). Property auto-selected from element type:
        # <input type=checkbox> → :checked, others → :value. Coexists
        # with data-field (form-spec §11.3) which adds form-scope
        # registration + error UI wiring; Compat raises on collision.
        [/\Adata-bind\z/,        :bind,        false],
        [/\Adata-show\z/,        :show,        false],
        [/\Adata-hide\z/,        :hide,        false],
        [/\Adata-each\z/,        :each,        false],
        [/\Adata-key\z/,         :key,         false],
        [/\Adata-class\z/,       :class_,      false],
        [/\Adata-component\z/,   :component,   false],
        [/\Adata-form\z/,        :form,        false],
        [/\Adata-field\z/,       :field,       false],
        [/\Adata-button\z/,      :button,      false],
        [/\Adata-on-(.+)\z/,     :on,          true],
        [/\Adata-attr-(.+)\z/,   :attr,        true],
        [/\Adata-css-(.+)\z/,    :css,         true],
      ].freeze

      def initialize(host)
        @host = host
        @evaluator = Evaluator.new(host)
        # Tracks observed plain `<form>` (no data-form) elements within this
        # component subtree. Used by `validate_form_element!` to raise on the
        # second occurrence (`:default` scope collision, form-spec §10.2.1).
        @default_form_seen = false
        # Suppresses repeated <input form="..."> warns within a single scan
        # (warn-once policy per spec §10.2.2).
        @input_form_attr_warned = false
      end

      def scan_and_bind
        scan_subtree(@host.root.to_js, item: nil)
      end

      # Walk + dispatch a subtree using one-pass collection + two-phase
      # dispatch (form-spec §17.4). Used both for the host's root scan and
      # for per-row scans inside `data-each` bodies — each per-row scan
      # gets its own 2-phase pass so derived state within a row also sees
      # field/button registrations in the row first.
      #
      # Phase A processes :field / :button (and the `<form>` element's
      # submit wire) so that all form-state registrations land before any
      # phase-B effect (data-text / data-class / data-on / ...) runs its
      # initial computation. Without this, a `<p data-text="@derived">`
      # placed before the `<input data-field="x">` it depends on would
      # raise on first effect run because form[:x] wouldn't exist yet.
      def scan_subtree(node_js, item:)
        records = []
        collect_subtree(node_js, item: item, records: records)
        records.each { |rec| dispatch_record(rec, phase: :a) }
        records.each { |rec| dispatch_record(rec, phase: :b) }
      end

      # Build records bottom-up via DFS. Stops descent at:
      #   - data-each elements (their body lives in a snapshot template,
      #     not the live DOM; dispatch_each in phase B handles per-row scan)
      #   - nested `data-component` subtrees (other components run their
      #     own Scanner pass)
      def collect_subtree(node_js, item:, records:)
        rec = build_record(node_js, item)
        records << rec if rec
        return if rec && rec[:directives].any? { |k, _, _| k == :each }
        if node_js != @host.root.to_js && node_js.call(:hasAttribute, "data-component").js_bool
          # Pre-resolve `data-prop-*` expressions on the nested data-component
          # element before it mounts. The child component's Props.build will
          # then see static literal attribute values that already incorporate
          # the parent's `it` / `@ivar` context.
          resolve_props(node_js, item)
          return
        end
        collect_children(node_js, item: item, records: records)
      end

      def collect_children(node_js, item:, records:)
        stack = [[node_js, item]]
        until stack.empty?
          current, current_item = stack.pop
          children = current[:children]
          length = children[:length].to_i
          # Push in reverse so document order is preserved when popped.
          (length - 1).downto(0) do |i|
            child = children[i]
            if child.call(:hasAttribute, "data-component").js_bool
              # Same pre-resolution rationale as collect_subtree's guard.
              resolve_props(child, current_item)
              next
            end

            rec = build_record(child, current_item)
            records << rec if rec

            # data-each owns descent into its body (template, not live DOM).
            next if rec && rec[:directives].any? { |k, _, _| k == :each }
            stack.push([child, current_item])
          end
        end
      end

      # For each `data-prop-*` attribute whose value parses as `@ivar` or
      # `it.field`, evaluate it against the current scope and write the
      # resolved scalar back as the attribute value. Pure literals (parse
      # failure OR bare ident — see below) are left untouched. Called
      # just before descent stops at a nested `data-component`, so the
      # child's `Props.build` reads a fully-resolved literal.
      #
      # **Bare-ident exclusion**: `data-prop-*` keeps the long-standing
      # convention that unparseable values (`data-prop-status="todo"`)
      # are literals. Bare ident in other directives means "item field",
      # but for data-prop-* the literal interpretation wins so that
      # `data-prop-status="todo"` remains a literal string. Iteration
      # field flow into child components goes through `PropAutoFill`
      # invoked at the end of this method.
      def resolve_props(el, item)
        # First pass: evaluate existing data-prop-* expressions (Ivar /
        # ItPath) so item context flows even if the user wrote the
        # attribute explicitly with `it.X`.
        names_js = el.call(:getAttributeNames)
        n = names_js[:length].to_i
        i = 0
        while i < n
          attr_name = names_js[i].to_s
          if attr_name.start_with?("data-prop-")
            raw = el.call(:getAttribute, attr_name).to_s
            value = Value.parse(raw)
            if value && !value.is_a?(Value::BareIdent)
              resolved = @evaluator.read(value, item)
              el.call(:setAttribute, attr_name, resolved.to_s)
            end
          end
          i += 1
        end

        # Second pass: fill in any unset data-prop-X attributes from the
        # iteration item by name match (data-each scope only). Owned by
        # `PropAutoFill` so the scanner doesn't accrete prop-mapping
        # responsibilities.
        PropAutoFill.fill_attributes(el, item)
      rescue Lilac::Error => e
        Lilac.logger.error("data-prop-*", e, source: @host)
      end

      # Per-element record built during collection. Captures everything
      # dispatch needs so phase A / B don't have to re-extract attributes.
      # Returns nil if the element has no directives AND isn't a `<form>`
      # (form elements still need wire_form_submit in phase A even without
      # any data-* directive).
      def build_record(el, item)
        tag = el[:tagName].to_s.downcase
        attrs = attribute_snapshot(el)
        descriptor = element_descriptor(el, tag)

        # Immediate side-effect checks (raise / warn-once) — must happen
        # during collection so we surface the error at the original DOM
        # position rather than later out of context.
        validate_form_element!(tag, attrs, descriptor) if tag == "form"
        warn_on_form_attr(tag, attrs) if attrs.key?("form")

        directives = extract_directives(el)
        is_form = (tag == "form")
        return nil if directives.empty? && !is_form

        skip = directives.empty? ? [] : Compat.check!(
          directives,
          tag_name: tag,
          attrs: attrs,
          element_descriptor: descriptor,
        )

        # data-form on non-<form> is a hard scope violation.
        if directives.any? { |k, _, _| k == :form } && !is_form
          raise Lilac::Error,
                "data-form is only allowed on <form> elements (got <#{tag}>, #{descriptor})"
        end

        {
          el: el, item: item, tag: tag, attrs: attrs,
          descriptor: descriptor, directives: directives,
          skip: skip, is_form: is_form,
        }
      rescue Lilac::Error => e
        Lilac.logger.error("directive", e, source: @host)
        nil
      end

      # Phase A: :field, :button, plus wire_form_submit on <form> elements.
      # Phase B: every other directive in DOM order.
      def dispatch_record(rec, phase:)
        return unless rec
        rec[:directives].each do |kind, name, raw_value|
          next if rec[:skip].include?(kind)
          next unless phase_matches?(phase, kind)
          dispatch(kind, name, raw_value, rec[:el], rec[:item], rec[:descriptor])
        end
        wire_form_submit(rec[:el], rec[:attrs]) if phase == :a && rec[:is_form]
      rescue Lilac::Error => e
        Lilac.logger.error("directive", e, source: @host)
      end

      def phase_matches?(phase, kind)
        if phase == :a
          kind == :field || kind == :button
        else
          kind != :field && kind != :button
        end
      end

      def extract_directives(el)
        names_js = el.call(:getAttributeNames)
        n = names_js[:length].to_i
        out = []
        i = 0
        while i < n
          attr_name = names_js[i].to_s
          DIRECTIVE_PATTERNS.each do |pattern, kind, captures_name|
            m = pattern.match(attr_name)
            next unless m
            name = captures_name ? m[1] : nil
            value = el.call(:getAttribute, attr_name).to_s
            out << [kind, name, value]
            break
          end
          i += 1
        end
        out
      end

      def attribute_snapshot(el)
        names_js = el.call(:getAttributeNames)
        n = names_js[:length].to_i
        out = {}
        i = 0
        while i < n
          attr_name = names_js[i].to_s
          out[attr_name.downcase] = el.call(:getAttribute, attr_name).to_s
          i += 1
        end
        out
      end

      # Short description for error / warn messages. No source-position
      # info at runtime; show the tag + a few key attributes instead.
      def element_descriptor(el, tag)
        ref = el.call(:getAttribute, "data-ref")
        if !ref.js_null? && !ref.to_s.empty?
          "<#{tag} data-ref=#{ref.to_s.inspect}>"
        else
          "<#{tag}>"
        end
      end

      # ---- per-directive dispatch ---------------------------------

      def dispatch(kind, name, raw_value, el, item, descriptor)
        case kind
        when :component, :key, :form
          # data-component: handled by Registry.
          # data-key:       orphan check filtered by Compat.
          # data-form:      scope marker; consumed during dispatch_field/button
          #                 ancestor walks. The <form> element's submit wire
          #                 happens in wire_form_submit (post-dispatch).
          nil
        when :text
          dispatch_value_bind(raw_value, el, item, "data-text", :text)
        when :unsafe_html
          dispatch_value_bind(raw_value, el, item, "data-unsafe-html", :html)
        when :bind
          dispatch_bind(raw_value, el, item)
        when :show
          dispatch_visibility(raw_value, el, item, "data-show", negate: true)
        when :hide
          dispatch_visibility(raw_value, el, item, "data-hide", negate: false)
        when :attr
          dispatch_attr(name, raw_value, el, item)
        when :css
          dispatch_css(name, raw_value, el, item)
        when :on
          dispatch_on(name, raw_value, el, item)
        when :each
          dispatch_each(raw_value, el, item)
        when :class_
          dispatch_class(raw_value, el, item)
        when :field
          dispatch_field(raw_value, el)
        when :button
          dispatch_button(raw_value, el)
        else
          # New directive added to DIRECTIVE_PATTERNS but no dispatcher —
          # signal loudly so the omission is caught in tests.
          raise Lilac::Error, "unhandled directive kind: #{kind.inspect}"
        end
      end

      # Both `it.path` (legacy) and `BareIdent` (new) reference fields on
      # the current iteration item, so they need silent-skip when scanning
      # outside any `data-each` body (e.g., the host root scan that
      # precedes / accompanies per-row scans).
      def requires_item?(value)
        value.is_a?(Value::ItPath) || value.is_a?(Value::BareIdent)
      end

      def dispatch_value_bind(raw_value, el, item, attr_label, prop)
        value = parse_value_or_raise(raw_value, attr_label)
        return if item.nil? && requires_item?(value)
        ref = wrap_ref(el)
        source = @evaluator.bind_source(value, item)
        @host.bind(ref, prop => source)
      end

      # data-bind: two-way input ↔ signal sync, form-independent.
      # Accepts `@ivar` (host Signal) or bare ident (current iteration
      # item's field — must resolve to a Signal stored in the item hash).
      # In both cases the underlying value must be a writable `Signal`;
      # Computed and plain values have no setter side. Target DOM property
      # is auto-selected from element type so HTML alone decides contract.
      def dispatch_bind(raw_value, el, item)
        value = parse_value_or_raise(raw_value, "data-bind")
        return if item.nil? && requires_item?(value)
        unless value.is_a?(Value::Ivar) || value.is_a?(Value::BareIdent)
          raise Lilac::Error,
                "data-bind requires @ivar or bare ident pointing at a writable " \
                "Signal (got #{raw_value.inspect}); it.path / literals have no setter"
        end
        signal = @evaluator.read_raw(value, item)
        unless signal.is_a?(Lilac::Signal)
          raise Lilac::Error,
                "data-bind=#{raw_value.inspect}: resolved value is not a Signal " \
                "(got #{signal.class}); two-way binding requires `signal(...)`, " \
                "not Computed / raw value"
        end
        tag = el[:tagName].to_s.downcase
        property = detect_bind_property(el, tag, raw_value)
        ref = wrap_ref(el)
        @host.bind_input(ref, signal, property: property)
      end

      # Pick the DOM property data-bind syncs against. Restricts to the
      # form-control trio so that `data-bind` on, say, a <div> raises
      # instead of silently wiring nothing useful.
      def detect_bind_property(el, tag, raw_value)
        case tag
        when "input"
          type_raw = el.call(:getAttribute, "type")
          type_str = type_raw.js_null? ? "text" : type_raw.to_s.downcase
          case type_str
          when "checkbox"
            :checked
          when "radio"
            raise Lilac::Error,
                  "data-bind on <input type=radio> is not supported yet; " \
                  "use data-on-change + manual signal update for now"
          when "file"
            raise Lilac::Error,
                  "data-bind on <input type=file> is not supported (the " \
                  "files property is read-only from script); use data-on-change"
          else
            :value
          end
        when "textarea", "select"
          :value
        else
          raise Lilac::Error,
                "data-bind=#{raw_value.inspect} is only allowed on " \
                "<input> / <textarea> / <select> (got <#{tag}>)"
        end
      end

      def dispatch_visibility(raw_value, el, item, attr_label, negate:)
        value = parse_value_or_raise(raw_value, attr_label)
        return if item.nil? && requires_item?(value)
        evaluator = @evaluator
        ref = wrap_ref(el)
        cond = @host.computed do
          v = evaluator.read(value, item)
          negate ? !v : !!v
        end
        @host.bind(ref, class: { "lil-hidden" => cond })
      end

      def dispatch_attr(name, raw_value, el, item)
        attr_name = name.to_s
        if Grammar.banned_attr?(attr_name)
          raise Lilac::Error,
                "data-attr-#{attr_name} targets a banned attribute " \
                "(on*/srcdoc/style). Use data-on-X for events, " \
                "data-css-X / RefElement#set_style for style."
        end
        value = parse_value_or_raise(raw_value, "data-attr-#{attr_name}")
        # Skip ItPath bindings when scanning without iteration context
        # (= the child component is scanning its own root, but `it` was a
        # parent-iteration concern already dispatched by the parent).
        return if item.nil? && requires_item?(value)
        ref = wrap_ref(el)
        @host.bind(ref, attr: { attr_name => @evaluator.bind_source(value, item) })
      end

      def dispatch_css(name, raw_value, el, item)
        css_name = name.to_s
        unless Grammar.kebab_name?(css_name)
          raise Lilac::Error,
                "data-css-#{css_name}: X must be kebab-lowercase " \
                "([a-z][a-z0-9-]*) and not start with `-`."
        end
        value = parse_value_or_raise(raw_value, "data-css-#{css_name}")
        return if item.nil? && requires_item?(value)
        ref = wrap_ref(el)
        evaluator = @evaluator
        @host.effect do
          ref.set_style("--#{css_name}", evaluator.read(value, item))
        end
      end

      # data-each iteration:
      #   1. Snapshot the data-each element's child HTML.
      #   2. Empty the live element (bind_list expects an empty
      #      container that it populates per item).
      #   3. Build an in-memory `<template>` from the snapshot.
      #   4. Resolve `data-key` to a key proc (fallback to object_id).
      #   5. Call host.bind_list with a per-item block that clones the
      #      template, recursively scans the clone with `item` bound,
      #      and returns it as a `Lilac::Template`.
      #
      # Nested data-each works naturally: when the per-row scan
      # encounters another data-each in the clone subtree, this same
      # dispatch_each fires with the inner `item` shadowing the outer.
      def dispatch_each(raw_value, el, parent_item)
        value = parse_value_or_raise(raw_value, "data-each")
        key_proc = build_key_proc(el)
        key_str = read_data_key_attr(el)

        cached_html = el[:innerHTML].to_s
        el[:innerHTML] = ""

        doc = JS.global[:document]
        tpl = doc.call(:createElement, "template")
        tpl[:innerHTML] = cached_html

        # Extract `data-prop-*` expressions from the original template once.
        # On clone the parent's `resolve_props` writes resolved scalars over
        # these attributes, so reading from the template (not the live row)
        # is the only way to recover the expressions on row reuse.
        row_prop_exprs = extract_row_prop_exprs(tpl)

        source = @evaluator.bind_source(value, parent_item)
        ref = wrap_ref(el)
        host = @host
        evaluator = @evaluator

        # Record (ref-name → source/key) on the host so mixins like
        # Sortable::List can look up the data-each binding by ref instead
        # of re-parsing data-each / data-key themselves. Only registers
        # when both data-ref and a parseable data-key are present —
        # consumers fall back to explicit args otherwise.
        ref_name = read_data_ref_attr(el)
        host.register_each_binding(ref_name, source, key_str) if ref_name && key_str

        @host.bind_list(ref, source, key: key_proc) do |it, prev_t|
          row_node =
            if prev_t
              # Reuse the existing cloned row — bind_list dispatches
              # to apply_template with same-node identity check, so
              # no DOM op is performed when nothing structural changed.
              prev_t.to_js
            else
              frag = tpl[:content].call(:cloneNode, true)
              frag[:firstElementChild]
            end
          # On row reuse, the child component is already mounted with its
          # initial prop values baked in — push fresh values through
          # `update_prop` so its prop Signals reflect the new item. This
          # covers two sources: (a) explicit data-prop-X="@ivar"/it.path
          # expressions captured at template extraction time, and (b)
          # auto-fill props (declared on the child class but not on the
          # template, populated from the iteration item on first mount).
          if prev_t
            push_prop_updates(row_node, it, row_prop_exprs, evaluator) unless row_prop_exprs.empty?
            PropAutoFill.push_updates(row_node, it, row_prop_exprs, host: host)
          end
          # Fresh Scanner per row keeps `@evaluator` bound to the same
          # host (so `@ivar` continues to resolve on the host) but
          # opens its own walk state.
          Scanner.new(host).scan_subtree(row_node, item: it)
          Lilac::Template.new(row_node, host)
        end
      end

      # Scan the row template's first element for `data-prop-*` attributes
      # whose value parses as `@ivar` / `it.field`. Returns
      # `{attr_name => Value}`. Empty hash if the row is not a
      # data-component or has no parseable prop expressions. BareIdent
      # is excluded — `data-prop-*` keeps the literal interpretation for
      # unparseable/bare values (see `resolve_props` for the rationale).
      def extract_row_prop_exprs(tpl)
        out = {}
        row_tpl_el = tpl[:content][:firstElementChild]
        return out if row_tpl_el.js_null?
        return out unless row_tpl_el.call(:hasAttribute, "data-component").js_bool
        names_js = row_tpl_el.call(:getAttributeNames)
        n = names_js[:length].to_i
        i = 0
        while i < n
          attr_name = names_js[i].to_s
          if attr_name.start_with?("data-prop-")
            raw = row_tpl_el.call(:getAttribute, attr_name).to_s
            v = Value.parse(raw)
            out[attr_name] = v if v && !v.is_a?(Value::BareIdent)
          end
          i += 1
        end
        out
      end

      # On row reuse: find the (already-mounted) child component and push
      # fresh prop values into its Signal ivars. Errors are logged, not
      # raised, so a single bad prop doesn't abort the whole reconcile.
      def push_prop_updates(row_node, item, prop_exprs, evaluator)
        child = Lilac.find_for_element(row_node)
        return unless child
        return unless child.respond_to?(:update_prop)
        prop_exprs.each do |attr_name, expr|
          prop_name = attr_name.sub("data-prop-", "").tr("-", "_").to_sym
          next unless child.class.prop_declarations.key?(prop_name)
          begin
            resolved = evaluator.read(expr, item)
            child.update_prop(prop_name, resolved.to_s)
          rescue Lilac::Error => e
            Lilac.logger.error("data-prop reuse #{attr_name}", e, source: @host)
          end
        end
      end

      def read_data_key_attr(el)
        raw = el.call(:getAttribute, "data-key")
        return nil if raw.js_null?
        s = raw.to_s.strip
        s.empty? ? nil : s
      end

      def read_data_ref_attr(el)
        raw = el.call(:getAttribute, "data-ref")
        return nil if raw.js_null?
        s = raw.to_s.strip
        s.empty? ? nil : s
      end

      # data-key="id" → ->(it) { it.id }. Without a valid data-key
      # value, fall back to object_id (stable for the render cycle —
      # CLI lint flags this case at build time as a warning).
      def build_key_proc(el)
        raw = el.call(:getAttribute, "data-key")
        field = raw.js_null? ? "" : raw.to_s.strip
        if field.empty? || !Grammar.method_ident?(field)
          return ->(it) { it.object_id } if field.empty?
          raise Lilac::Error,
                "data-key: #{field.inspect} is not a bare field name " \
                "(use `data-key=\"id\"` — no `it.` prefix, no `@`, no `.`, no `?`)"
        end
        sym = field.to_sym
        ->(it) do
          if it.is_a?(Hash)
            it.key?(sym) ? it[sym] : it[field]
          else
            it.public_send(sym)
          end
        end
      end

      # data-class hash literal: parse into pairs, validate each value
      # as ivar/it_path, then bind via the existing class: hash form.
      def dispatch_class(raw_value, el, item)
        pairs =
          begin
            ClassParser.parse(raw_value)
          rescue ClassParser::Error => e
            raise Lilac::Error, "data-class: #{e.message}"
          end
        # Reserved-name check: `lil-hidden` is owned by data-show / data-hide.
        # Bare ergonomics (warn-and-skip) would silently override the user's
        # visibility intent, so we treat overlap as correctness and raise.
        pairs.each do |key, _|
          if key == "lil-hidden"
            raise Lilac::Error,
                  "data-class: `lil-hidden` is reserved for data-show / data-hide; " \
                  "remove it from data-class or use a different class name"
          end
        end
        bound = {}
        pairs.each do |key, raw|
          value = parse_value_or_raise(raw, "data-class[#{key.inspect}]")
          bound[key] = @evaluator.bind_source(value, item)
        end
        @host.bind(wrap_ref(el), class: bound)
      end

      def dispatch_on(name, raw_value, el, item)
        method_name = raw_value.to_s.strip
        unless Grammar.method_ident?(method_name)
          raise Lilac::Error,
                "data-on-#{name}: #{raw_value.inspect} " \
                "(expected a method name; `?` predicate and `!` bang are banned)"
        end
        ref = wrap_ref(el)
        event_sym = name.to_sym
        host = @host
        method_sym = method_name.to_sym
        if item
          captured_item = item
          ref.on(event_sym) { |ev| host.public_send(method_sym, captured_item, ev) }
        else
          ref.on(event_sym) { |ev| host.public_send(method_sym, ev) }
        end
      end

      # Generic accept-anything (ivar or it.path) parse.
      def parse_value_or_raise(raw_value, attr_label)
        value = Value.parse(raw_value)
        unless value
          raise Lilac::Error,
                "Invalid value for #{attr_label}: #{raw_value.inspect} " \
                "(expected `@ivar` or `it.path`)"
        end
        value
      end

      def wrap_ref(el_js)
        Lilac::RefElement.new(el_js, @host)
      end
    end
  end
end
