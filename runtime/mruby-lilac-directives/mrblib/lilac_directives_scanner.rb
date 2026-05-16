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
        [/\Adata-component\z/,   :component,   false],
        [/\Adata-on-(.+)\z/,     :on,          true],
        [/\Adata-attr-(.+)\z/,   :attr,        true],
        [/\Adata-css-(.+)\z/,    :css,         true],
      ].freeze

      def initialize(host)
        @host = host
        @evaluator = Evaluator.new(host)
      end

      def scan_and_bind
        root_js = @host.root.to_js
        walk(root_js, item: nil)
      end

      # Iterative descent so deeply-nested templates don't blow the
      # mruby stack. Children of the root are processed first; we then
      # recurse into each (except across nested-component boundaries
      # and into-data-each bodies, which are out of scope for Phase 1).
      def walk(node_js, item:)
        stack = [[node_js, item]]
        until stack.empty?
          current, current_item = stack.pop
          children = current[:children]
          length = children[:length].to_i
          # Push in reverse so document order is preserved when popped.
          (length - 1).downto(0) do |i|
            child = children[i]
            next if nested_component_root?(child, current)

            kinds_present = process_element(child, current_item)

            # Phase 1: data-each pauses descent (the iteration body's
            # bindings need data-each support to be meaningful, which
            # arrives in Phase 3). Once supported, the each handler
            # will own the recursive scan of its body.
            next if kinds_present.include?(:each)

            stack.push([child, current_item])
          end
        end
      end

      # An element is a "nested component root" when:
      #   - it has `data-component`,
      #   - it is not the host's own root.
      # The host's own root carries `data-component` itself but must
      # still be scanned (its directives belong to this component).
      def nested_component_root?(el, parent)
        return false if el == @host.root.to_js
        el.call(:hasAttribute, "data-component").js_bool
      end

      # Extract + dispatch all directives on a single element.
      # Returns the set of directive kinds present (used by `walk` to
      # decide whether to descend).
      def process_element(el, item)
        directives = extract_directives(el)
        return [] if directives.empty?

        tag = el[:tagName].to_s.downcase
        attrs = attribute_snapshot(el)
        descriptor = element_descriptor(el, tag)

        skip = Compat.check!(
          directives,
          tag_name: tag,
          attrs: attrs,
          element_descriptor: descriptor,
        )

        directives.each do |kind, name, raw_value|
          next if skip.include?(kind)
          dispatch(kind, name, raw_value, el, item, descriptor)
        end

        directives.map { |k, _, _| k }
      rescue Lilac::Error => e
        # Raised by Compat or dispatchers for correctness/security
        # violations. Route through the component logger so the
        # nearest error_boundary catches it, then continue scanning
        # the rest of the tree.
        Lilac.logger.error("directive", e, source: @host)
        []
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
        when :component, :key
          # data-component is handled by the Registry; orphan data-key
          # was already filtered by Compat.
          nil
        when :text
          dispatch_value_bind(raw_value, el, item, "data-text", :text)
        when :unsafe_html
          dispatch_value_bind(raw_value, el, item, "data-unsafe-html", :html)
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
          Lilac.logger.warn(
            "data-each is not supported in Phase 1 runtime scanner (#{descriptor}); " \
            "use lilac-cli for now, or wait for Phase 3"
          )
        when :value, :checked, :class_
          Lilac.logger.warn(
            "data-#{Compat.kind_label(kind)} arrives in Phase 2 runtime scanner (#{descriptor}); " \
            "use lilac-cli for now"
          )
        else
          # New directive added to DIRECTIVE_PATTERNS but no dispatcher —
          # signal loudly so the omission is caught in tests.
          raise Lilac::Error, "unhandled directive kind: #{kind.inspect}"
        end
      end

      def dispatch_value_bind(raw_value, el, item, attr_label, prop)
        value = parse_value_or_raise(raw_value, attr_label)
        ref = wrap_ref(el)
        source = @evaluator.bind_source(value, item)
        @host.bind(ref, prop => source)
      end

      def dispatch_visibility(raw_value, el, item, attr_label, negate:)
        value = parse_value_or_raise(raw_value, attr_label)
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
        ref = wrap_ref(el)
        evaluator = @evaluator
        @host.effect do
          ref.set_style("--#{css_name}", evaluator.read(value, item))
        end
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

      # Phase 1 doesn't support `it.field` paths because they only
      # become meaningful inside `data-each` (Phase 3). Reject early
      # with a clear message rather than letting Evaluator NPE.
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
