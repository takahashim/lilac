module Lilac
  module Directives
    # Stable per-element argument passed to `Handler#wire`. Wraps the
    # scanner + host component so package authors don't reach into
    # framework internals directly — anything they need lives on Context
    # (or, escape hatch, on `ctx.advanced`).
    #
    # Lifecycle: one Context is built per (handler, element, item) triple
    # during the owning component's mount. It's not retained after `wire`
    # returns — handlers that need post-mount work should call
    # `ctx.after_mount { ... }` to register a deferred block.
    #
    # See ADR-0027 for the surface rationale (class-first principle,
    # Vue-directive-style helpers). New helpers are added here as needed
    # rather than exposing scanner / component internals to packages.
    class Context
      attr_reader :attribute_name, :element, :item

      # `scanner`         — Lilac::Directives::Scanner (kept for `advanced`)
      # `attribute_name`  — the matched `data-*` attribute name (e.g. "data-tooltip")
      # `raw_value`       — String returned by `el.getAttribute(attribute_name)`
      # `element`         — Lilac::RefElement wrapping the matched element
      # `item`            — current `data-each` iteration item, or `nil` when
      #                     scanning outside any iteration body
      def initialize(scanner:, attribute_name:, raw_value:, element:, item:)
        @scanner = scanner
        @attribute_name = attribute_name
        @raw_value = raw_value
        @element = element
        @item = item
      end

      # True when `wire` is invoked inside a `data-each` body, so
      # bare-ident `Value`s in the attribute resolve to fields of the
      # current row's item.
      def iteration?
        !@item.nil?
      end

      # Untouched String form of the attribute value (e.g. "Save" for
      # `data-tooltip="Save"`, or "@label" for the reactive form). Empty
      # string when the attribute is present without a value.
      def raw_value
        @raw_value
      end

      # Parsed `Value` (Ivar / BareIdent) when the raw text is a
      # reactive reference; otherwise the raw String for literal use.
      # Returns `nil` only when the raw value is empty — handlers can
      # use `return unless ctx.value` to short-circuit on empty input.
      def value
        return @value if instance_variable_defined?(:@value)
        s = @raw_value.to_s
        @value = if s.empty?
                   nil
                 else
                   Value.parse(s) || s
                 end
      end

      # Reactively (or, for literals, eagerly) bind a single HTML
      # attribute. `to:` accepts:
      #   - `Value::Ivar`      — host `@ivar` Signal/Computed; rebinds
      #                          on every change
      #   - `Value::BareIdent` — current iteration item field (silently
      #                          skipped when called outside a data-each
      #                          body, matching built-in directive
      #                          semantics)
      #   - any String         — set once at mount; no reactive link
      def bind_attribute(name, to:)
        case to
        when Value::Ivar
          source = @scanner.evaluator.bind_source(to, @item)
          @scanner.host.bind(@element, attr: { name.to_s => source })
        when Value::BareIdent
          return if @item.nil?
          source = @scanner.evaluator.bind_source(to, @item)
          @scanner.host.bind(@element, attr: { name.to_s => source })
        else
          @element.attr(name.to_s, to.to_s)
        end
      end

      # Sugar for `element.on(event) { ... }` so handlers can stay on
      # the Context surface without grabbing `ctx.element` explicitly.
      # Listener teardown is the same as `RefElement#on` (auto-removed
      # when the host component unmounts).
      def on(event, options = nil, &block)
        @element.on(event, options, &block)
      end

      # The `Lilac::Component` instance the directive is wiring into.
      # Stable surface — exposes the component-level API (`bind`,
      # `effect`, `computed`, `signal`, `form(...)`, ...). Prefer the
      # Context helpers (`bind_attribute`, `on`, ...) when they cover
      # the case; reach for `ctx.host` when the directive needs the
      # full Component surface (e.g. form's `host.form(sym)` lookup).
      def host
        @scanner.host
      end

      # Wrap a raw `JS::Object` DOM element as a `RefElement` bound to
      # the host component. Useful when the directive walks the DOM to
      # locate a descendant element (e.g. form's `data-field` finding
      # the inner `<input>`) and needs to bind / listen on it through
      # the framework's ergonomic API.
      def wrap(js_element)
        @scanner.host.wrap(js_element)
      end

      # Short `<tag data-ref="...">` form for error / warn messages.
      # Mirrors the scanner's internal `element_descriptor` so handler
      # error messages match the framework's wording.
      def descriptor
        return @descriptor if instance_variable_defined?(:@descriptor)
        el = @element.to_js
        tag = el[:tagName].to_s.downcase
        ref = el.call(:getAttribute, "data-ref")
        @descriptor =
          if !ref.js_null? && !ref.to_s.empty?
            "<#{tag} data-ref=#{ref.to_s.inspect}>"
          else
            "<#{tag}>"
          end
      end

      # Queue a block to run after the component's `bind_template_hook`
      # phase completes — i.e. once every directive on every element has
      # finished wiring. Useful for handlers that need the element to be
      # in its final bound state (e.g. autofocus, scroll-into-view) but
      # not the right place for reactive bindings (use `bind_attribute`
      # for those instead).
      def after_mount(&block)
        raise ArgumentError, "after_mount requires a block" unless block
        @scanner.host.defer_until_bound(&block)
      end

      # Escape hatch to the scanner + host component. UNSTABLE — the
      # internals it exposes can change between Lilac versions without
      # notice. Use only when Context's stable helpers don't cover the
      # case, and consider filing an issue so the missing helper can be
      # added properly.
      def advanced
        @advanced ||= Advanced.new(@scanner)
      end

      class Advanced
        attr_reader :scanner

        def initialize(scanner)
          @scanner = scanner
        end

        def host
          @scanner.host
        end

        def evaluator
          @scanner.evaluator
        end
      end
    end
  end
end
