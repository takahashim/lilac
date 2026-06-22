# lilac_ref.rb — RefElement / Refs / TemplateRefs / Template.
#
# DOM element wrappers + ref lookup proxies. Grouped here because they
# share the "JS::Object element + Component back-ref + ref lookup" theme
# and form the bridge layer between raw DOM and the Bindable / Component
# DSLs that consume them.
#
# Loaded after lilac.rb (Lilac module + AttrName).

module Lilac
  # Turbo Streams-style basic DOM operations as explicit Ruby methods.
  # Avoids `method_missing` pass-through so IDEs can complete and readers
  # can tell apart "Ruby method call" from "raw JS pass-through". Included
  # into both RefElement and Template; including classes must define
  # `to_js` returning the wrapped JS::Object.
  #
  # Variadic `other` args accept RefElement / Template / JS::Object /
  # String. Strings are converted to Text nodes (DOM `Element.append(...)`
  # accepts strings natively, but the mruby → JS bridge for plain strings
  # is unstable in places, so coerce on the Ruby side).
  #
  # Return value: ops that leave self in the DOM (append/prepend/before/
  # after) return self for chaining. Ops that detach self (remove/
  # replace_with) return nil so chained misuse fails fast.
  module NodeOperations
    def append(*others)
      to_js.call(:append, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def prepend(*others)
      to_js.call(:prepend, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def before(*others)
      to_js.call(:before, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def after(*others)
      to_js.call(:after, *others.map { |o| NodeOperations.coerce_node(o) })
      self
    end

    def remove
      to_js.call(:remove)
      nil
    end

    def replace_with(*others)
      to_js.call(:replaceWith, *others.map { |o| NodeOperations.coerce_node(o) })
      nil
    end

    # RefElement / Template are unwrapped via `to_js`. Strings are
    # converted to Text nodes via `document.createTextNode` — DOM's
    # `Element.append(...)` accepts strings natively, but the mruby → JS
    # bridge for plain strings can drop the value, so coerce explicitly.
    # Anything else (JS::Object etc.) is passed through.
    def self.coerce_node(arg)
      case arg
      when RefElement, Template
        arg.to_js
      when String
        JS.global[:document].call(:createTextNode, arg)
      else
        arg
      end
    end
  end

  # Wraps a JS DOM element together with a back-reference to the
  # owning component. Lets `el.on(:click)` register a listener that gets
  # auto-removed on component unmount, and `el.component` resolve to a child
  # Lilac::Component instance when the element is itself a `data-component`
  # root.
  #
  # Unrecognised methods fall through to the wrapped JS::Object so the
  # element behaves like a plain JS::Object handle for advanced use.
  class RefElement
    include NodeOperations

    # Bound DOM properties exposed on RefElement. Each tuple is
    # `[ruby_name, js_dom_property, kind]`. `kind` controls cast:
    #   :string — getter returns String, setter does `v.to_s`
    #   :bool   — getter returns Ruby Boolean, setter does `!!v`
    PROPS = [
      [:text,     :textContent, :string],
      [:html,     :innerHTML,   :string],
      [:value,    :value,       :string],
      [:hidden,   :hidden,      :bool],
      [:disabled, :disabled,    :bool],
      [:checked,  :checked,     :bool],
    ].freeze

    BIND_PROPS = PROPS.map { |name, _, _| name }.freeze

    attr_reader :js, :component, :name

    def initialize(js_object, component, name: nil)
      @js = js_object
      @component = component
      @name = name
    end

    # Register a DOM event listener. The callback is tracked on the
    # owning component so it gets removed (and the JS::Object callback
    # handle released) on unmount. The block is wrapped so that a
    # raise routes through `Lilac.logger.error` (and bubbles up to the
    # nearest `on_error` / `error_boundary`) rather than being printed
    # by `mrb_print_error` and dropped.
    def on(event, options = nil, &block)
      raise ArgumentError, "block required" unless block
      evt = event.to_s
      component = @component
      cb = JS.callback do |*args|
        begin
          block.call(*args)
        rescue => e
          Lilac.logger.error("listener (#{evt})", e, source: component)
        end
      end
      if options
        @js.call(:addEventListener, evt, cb, options)
      else
        @js.call(:addEventListener, evt, cb)
      end
      @component.track_listener(@js, evt, cb) if @component
      cb
    end

    # Await a DOM event as a Promise — no hand-rolled
    # `JS.global[:Promise].new(...)`:
    #
    #   event = refs.track.once(:load, error: :error).await
    #
    # Resolves with the event object the first time `event` fires;
    # if any `error:` event (a Symbol or Array of them) fires first,
    # rejects with that event. Both listeners are registered
    # `{ once: true }`, and when either settles — or the owning
    # component unmounts first — the rest are removed and every
    # callback released, so nothing leaks even if the losing event
    # never fires. Must be awaited inside an async context (a fiber),
    # the same precondition as any other `.await`.
    def once(event, error: nil)
      want = event.to_s
      error_events =
        if error.nil? then []
        elsif error.is_a?(Array) then error.map(&:to_s)
        else [error.to_s]
        end
      js = @js
      once_opt = JS.object(once: true)
      Lilac.promise do |resolve, reject|
        subs = []
        settled = false
        teardown = lambda do
          next if settled
          settled = true
          subs.each do |evt, cb|
            js.call(:removeEventListener, evt, cb)
            JS.release_callback(cb)
          end
          subs.clear
        end
        @component.cleanup { teardown.call } if @component
        listen = lambda do |evt, settle_with|
          cb = JS.callback do |ev|
            teardown.call
            settle_with.call(ev)
          end
          js.call(:addEventListener, evt, cb, once_opt)
          subs << [evt, cb]
        end
        listen.call(want, resolve)
        error_events.each { |evt| listen.call(evt, reject) }
      end
    end

    # Fire a `CustomEvent` on the wrapped DOM element. Throws at
    # runtime if `@js` isn't an EventTarget — same trade-off Lilac
    # has always accepted for keeping `refs.x.dispatch(...)` natural.
    def dispatch(name, detail: nil, bubbles: false)
      init = JS.object(bubbles: bubbles)
      init[:detail] = JS.wrap(detail) unless detail.nil?
      ev = Lilac.__window__[:CustomEvent].new(name.to_s, init)
      @js.call(:dispatchEvent, ev)
    end

    PROPS.each do |name, js_key, kind|
      case kind
      when :string
        define_method(name) { @js[js_key].to_s }
        define_method("#{name}=") do |v|
          @js[js_key] = v.to_s
          v
        end
      when :bool
        define_method(name) { @js[js_key].js_bool }
        define_method("#{name}=") do |v|
          @js[js_key] = !!v
          v
        end
      end
    end

    # HTML attribute read/write/remove. Mirrors Template#attr.
    #   ref.attr("data-id")            → "42" or nil
    #   ref.attr("data-id", 42)        → writes setAttribute (to_s coerced)
    #   ref.attr("data-id", nil)       → removeAttribute (matches set_style semantics)
    ATTR_NO_VALUE = Object.new.freeze
    def attr(name, value = ATTR_NO_VALUE)
      if value.equal?(ATTR_NO_VALUE)
        v = @js.call(:getAttribute, name.to_s)
        v.js_null? ? nil : v.to_s
      elsif value.nil?
        @js.call(:removeAttribute, name.to_s)
        nil
      else
        @js.call(:setAttribute, name.to_s, value.to_s)
        value
      end
    end

    # `data-*` shortcut. `ref.data(:id)` ≡ `ref.attr("data-id")`.
    # Symbol/String の underscore は hyphen に変換: `data(:user_id)` →
    # `data-user-id` (HTML5 の dataset.userId と素直に対応するため)。
    def data(name, value = ATTR_NO_VALUE)
      attr("data-#{name.to_s.tr("_", "-")}", value)
    end

    def toggle_class(name, force)
      @js[:classList].call(:toggle, name.to_s, !!force)
    end

    def set_style(property, value)
      style = @js[:style]
      if value.nil? || value == false
        style.call(:removeProperty, property.to_s)
      else
        style.call(:setProperty, property.to_s, value.to_s)
      end
    end

    # The Component instance attached to this element. Raises if the
    # element is not itself a `data-component` root.
    def component_instance
      Lilac.find_for_element(@js) ||
        raise(Lilac::Error,
              "Missing component on ref: #{@name || "(unknown)"} in #{@component ? @component.class.name : "(no component)"}")
    end

    # `component` reads naturally in the spec: `refs.left.component.reset`.
    alias_method :component, :component_instance

    def to_js
      @js
    end

    def method_missing(sym, *args, &block)
      @js.__send__(sym, *args, &block)
    end

    def respond_to_missing?(_sym, _include_private = false)
      true
    end
  end

  # Shared base for `Refs` (mounted component root) and `TemplateRefs`
  # (cloned `<template>` subtree). Both flavours:
  #
  #   - cache `data-ref`-named elements as `RefElement` for direct lookup
  #   - keep a positional `@positional` array (DFS preorder, directive-
  #     bearing AND `data-ref`-bearing) so codegen's `refs.lilN` resolves
  #     to "the Nth ref slot in this scope" (decisions §19)
  #   - stop descent at nested `data-component` subtrees (those own their
  #     own ref scope), while the root itself is always visited
  #
  # Subclasses customise only:
  #
  #   - what `root_js` to walk (constructor — Refs derives it from the
  #     component, TemplateRefs receives it directly)
  #   - the wording of the "not found" raise (`missing_ref_message`)
  #
  # See decisions §19 for the positional `lilN` design.
  class RefLookupBase
    # `lilN` is the codegen positional namespace (decisions §19) —
    # synthetic refs are never written into the DOM as `data-ref`
    # attributes, so a missing entry in `@cache` for that namespace
    # triggers a positional fallback against `@positional` (DFS order
    # over directive-bearing descendants).
    LILN_RE = /\Alil(\d+)\z/

    # SSOT-paired with `Lilac::Directives::Grammar::DIRECTIVE_ATTR` in
    # both `cli/lib/lilac/directives/grammar.rb` and
    # `runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb`.
    # We duplicate it here so the positional walk also works in
    # `lilac-compiled` (which excludes the scanner gem to save bundle
    # size). Keep the three regexes byte-identical.
    DIRECTIVE_ATTR_RE = /^data-(?:text|unsafe-html|bind|show|hide|each|key|class|form|field|button|on-.+|attr-.+|css-.+)$/

    def initialize(root_js, component)
      @component = component
      @cache = {}
      @positional = []
      # DFS preorder: matches the build-time TemplateAST walk so
      # codegen's `lilN` (Nth directive-bearing element in scope) lines
      # up with `@positional[N]` here.
      collect_node(root_js, true)
    end

    def [](name)
      key = name.to_s
      el = @cache[key]
      return el if el
      if (m = LILN_RE.match(key))
        idx = m[1].to_i
        js = @positional[idx]
        if js
          el = RefElement.new(js, @component, name: key)
          @cache[key] = el
          return el
        end
      end
      raise Lilac::Error, missing_ref_message(key)
    end

    def method_missing(sym, *args)
      unless args.empty? && !block_given?
        raise NoMethodError, "#{lookup_label}.#{sym} takes no arguments or block"
      end
      self[sym]
    end

    def respond_to_missing?(_sym, _include_private = false)
      true
    end

    private

    # Subclass label used in NoMethodError text. Default to the class's
    # short name so the message says e.g. `Refs.foo` / `TemplateRefs.bar`
    # (matching the pre-refactor wording).
    def lookup_label
      self.class.name.to_s.split("::").last
    end

    # Subclasses override.
    def missing_ref_message(_key)
      raise NotImplementedError
    end

    # Iterative DFS over the subtree. Records [data-ref] elements as
    # RefElements. Does not descend into nested `data-component`
    # subtrees, but DOES collect refs declared on the nested component's
    # *root* element (which belongs to the parent's scope per the spec).
    #
    # Walks `root_js` ITSELF first — TemplateAST may emit a synthetic
    # `data-ref="lilN"` on the component's root element when a directive
    # (`data-class` / `data-attr-*` / `data-css-*` / etc.) is declared
    # there, and the CLI codegen path's `refs.lilN` lookup must resolve
    # to the root. The runtime scanner path, which walks the component
    # subtree directly without going through `refs`, was unaffected and
    # therefore the gap stayed hidden until the `:compiled` build target
    # (codegen-only, no scanner) started exercising `refs` for root
    # bindings.
    def collect_node(node, is_root)
      ref_attr = node.call(:getAttribute, "data-ref")
      has_ref = !ref_attr.js_null?
      if has_ref
        name = ref_attr.to_s
        unless @cache[name]
          @cache[name] = RefElement.new(node, @component, name: name)
        end
      end
      # Stop descent at a nested data-component (its subtree owns
      # its own Refs). The check is skipped for the initial root
      # itself — otherwise we'd visit zero elements.
      unless is_root
        component_attr = node.call(:getAttribute, "data-component")
        return if !component_attr.js_null?
      end
      # An element claims a `lilN` slot iff it took a ref slot at build
      # time — i.e. it carries a directive OR a user-declared
      # `data-ref`. TemplateAST counts both toward `current_ref_scope.size`
      # when allocating synthetic indices, so the runtime DFS has to
      # mirror that to keep `refs.lilN` aligned across user-named
      # refs that sit on directive-less elements (e.g. `<button data-ref="inc">`).
      if has_ref || directive_bearing?(node)
        @positional << node
      end
      kids = node[:children]
      kn = kids[:length].to_i
      ki = 0
      while ki < kn
        collect_node(kids[ki], false)
        ki += 1
      end
    end

    # Element counts toward the `lilN` positional list iff it carries at
    # least one `data-*` attribute that maps to a directive. Mirrors
    # TemplateAST's `has_real_directive` so build/runtime stay in
    # lockstep. See `DIRECTIVE_ATTR_RE` above for the SSOT pattern.
    def directive_bearing?(node)
      attrs = node[:attributes]
      n = attrs[:length].to_i
      i = 0
      while i < n
        a = attrs[i]
        name = a[:name].to_s
        return true if DIRECTIVE_ATTR_RE.match?(name)
        i += 1
      end
      false
    end
  end

  # Refs — proxy returning RefElement instances by name. Built once per
  # component mount by walking the root's subtree.
  class Refs < RefLookupBase
    def initialize(component)
      super(component.root.to_js, component)
    end

    private

    def missing_ref_message(key)
      "Missing ref: #{key} in #{@component.class.name}"
    end
  end

  # Ref lookup over a cloned `<template>` subtree. Both user-declared
  # `data-ref` and codegen positional `lilN` (decisions §19) resolve
  # through the same DFS walk that `Refs` uses on the mounted root —
  # the template clone isn't mounted yet, but its DOM shape is the same
  # so the rules carry over.
  class TemplateRefs < RefLookupBase
    private

    def missing_ref_message(key)
      "Missing template ref: #{key}"
    end
  end

  # Wrapper around a DOM element with lazy `refs`. Returned by
  # `template(name)`; the public constructor wraps an arbitrary
  # JS::Object so external (non-template) elements can flow through
  # `bind_list` without raw-element handling.
  class Template
    include NodeOperations

    # Clone `<template data-template="NAME">` from the document and
    # wrap its first element child as a Template. `component` is consulted
    # by `TemplateRefs` for listener auto-cleanup tracking when the
    # cloned content's RefElements register events.
    def self.from_document(name, component = nil)
      name = AttrName.new(name, kind: "data-template")
      tpl = JS.global[:document].call(:querySelector, "template[data-template=\"#{name}\"]")
      raise Error, "Missing template: #{name}" if tpl.js_null?
      frag = tpl[:content].call(:cloneNode, true)
      clone = frag[:firstElementChild]
      raise Error, "Empty template: #{name}" if clone.js_null?
      t = new(clone, component)
      yield t.refs if block_given?
      t
    end

    def initialize(node, component = nil)
      @node = node
      @component = component
      @refs = nil
    end

    def refs
      @refs ||= TemplateRefs.new(@node, @component)
    end

    def to_js
      @node
    end

    # HTML attribute read/write/remove on the cloned root. Same shape as
    # `RefElement#attr` so per-row code reads consistently:
    #
    #   bind_list refs.list, items, key: "id", template: "row" do |it, t|
    #     t.data(:id, it["id"])
    #   end
    def attr(name, value = RefElement::ATTR_NO_VALUE)
      if value.equal?(RefElement::ATTR_NO_VALUE)
        v = @node.call(:getAttribute, name.to_s)
        v.js_null? ? nil : v.to_s
      elsif value.nil?
        @node.call(:removeAttribute, name.to_s)
        nil
      else
        @node.call(:setAttribute, name.to_s, value.to_s)
        value
      end
    end

    def data(name, value = RefElement::ATTR_NO_VALUE)
      attr("data-#{name.to_s.tr("_", "-")}", value)
    end
  end
end
