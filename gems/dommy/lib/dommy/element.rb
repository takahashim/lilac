# frozen_string_literal: true

require "uri"

require_relative "parser"

module Dommy
  class Fragment
    include EventTarget
    include Node

    attr_reader :__node__, :document

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
    end

    # Public Ruby API (DocumentFragment surface)

    def children
      element_children
    end

    def child_element_count
      @__node__.element_children.size
    end

    def child_nodes
      @__node__.children.map { |n| @document.wrap_node(n) }.compact
    end

    def first_child
      @document.wrap_node(@__node__.children.first)
    end

    def last_child
      @document.wrap_node(@__node__.children.last)
    end

    def first_element_child
      @document.wrap_node(@__node__.children.find(&:element?))
    end

    def last_element_child
      @document.wrap_node(@__node__.element_children.last)
    end

    def text_content
      @__node__.text
    end

    def append_child(child)
      nodes = detach_dom_nodes(child)
      nodes.each { |n| @__node__.add_child(n) }
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      child
    end

    def query_selector(selector)
      return nil if selector.nil? || selector.to_s.empty?

      @document.wrap_node(@__node__.at_css(selector.to_s))
    end

    def query_selector_all(selector)
      return NodeList.new if selector.nil? || selector.to_s.empty?

      NodeList.new(@__node__.css(selector.to_s).map { |n| @document.wrap_node(n) }.compact)
    end

    def get_element_by_id(id)
      return nil if id.nil?

      @document.wrap_node(@__node__.at_css("##{id}"))
    end

    def __js_get__(key)
      case key
      when "nodeType"          then 11
      when "children"          then element_children
      when "childNodes"        then child_nodes
      when "childElementCount" then child_element_count
      when "firstChild"        then first_child
      when "lastChild"         then last_child
      when "firstElementChild" then first_element_child
      when "lastElementChild"  then last_element_child
      when "textContent"       then @__node__.text
      end
    end

    def __js_call__(method, args)
      case method
      when "cloneNode"
        deep = args.empty? ? false : !!args[0]
        deep ? @document.wrap_node(Parser.fragment(@__node__.to_html, owner_doc: @document.nokogiri_doc)) : @document.wrap_node(Parser.fragment("", owner_doc: @document.nokogiri_doc))
      when "querySelector"
        query_selector(args[0])
      when "querySelectorAll"
        query_selector_all(args[0])
      when "getElementById"
        get_element_by_id(args[0])
      when "appendChild"
        append_child(args[0])
      else
        nil
      end
    end

    def extract_children
      nodes = @__node__.children.to_a
      nodes.each(&:unlink)
      nodes
    end

    private

    def detach_dom_nodes(value)
      case value
      when String
        [@document.create_text_node(value).__node__]
      else
        node = value.respond_to?(:__node__) ? value.__node__ : nil
        return [] unless node

        node.unlink if node.parent
        [node]
      end
    end

    def element_children
      @__node__.element_children.each_with_object([]) do |node, out|
        wrapped = @document.wrap_node(node)
        out << wrapped if wrapped
      end
    end

    # Fragments aren't part of the bubble chain; nil terminates
    # bubbling at the boundary (shadow root, detached fragment, etc.).
    def __event_parent__
      nil
    end
  end

  # CharacterData base — TextNode and CommentNode share the data /
  # nodeValue / textContent API and `remove` / `cloneNode` semantics.
  class CharacterDataNode
    include Node

    attr_reader :__node__

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
    end

    # Snake_case facade (CRuby idiomatic)

    def data
      @__node__.content
    end

    def data=(value)
      write_data(value)
    end

    def node_value
      @__node__.content
    end

    def node_value=(value)
      write_data(value)
    end

    def text_content
      @__node__.content
    end

    def text_content=(value)
      write_data(value)
    end

    def remove
      @__node__.unlink
      nil
    end

    def parent_node
      @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    def next_sibling
      @__node__.next && @document.wrap_node(@__node__.next)
    end

    def previous_sibling
      @__node__.previous && @document.wrap_node(@__node__.previous)
    end

    def [](key)
      __js_get__(key.to_s)
    end

    def []=(key, value)
      __js_set__(key.to_s, value)
    end

    def __js_get__(key)
      case key
      when "nodeType"      then node_type
      when "textContent"   then @__node__.content
      when "data"          then @__node__.content
      when "nodeValue"     then @__node__.content
      when "parentNode"    then parent_node
      when "nextSibling"   then next_sibling
      when "previousSibling" then previous_sibling
      end
    end

    def __js_set__(key, value)
      case key
      when "textContent", "data", "nodeValue"
        write_data(value)
      end
      nil
    end

    def __js_call__(method, _args)
      case method
      when "remove"
        @__node__.unlink
        nil
      end
    end

    private

    def write_data(value)
      old = @__node__.content
      @__node__.content = value.to_s
      @document.notify_character_data_mutation(target_node: @__node__, old_value: old)
    end
  end

  class TextNode < CharacterDataNode
    def node_type
      3
    end

    def __js_call__(method, args)
      case method
      when "cloneNode"
        @document.create_text_node(@__node__.text)
      else
        super
      end
    end
  end

  class CommentNode < CharacterDataNode
    def node_type
      8
    end

    def __js_call__(method, args)
      case method
      when "cloneNode"
        @document.create_comment(@__node__.content)
      else
        super
      end
    end
  end

  # Live HTMLCollection equivalent. Each `[:length]` / `["0"]` /
  # `["1"]` read re-walks the underlying Nokogiri element_children,
  # so callers that snapshot `el[:children]` at the top of a loop
  # still see DOM mutations performed inside the loop. Lilac's
  # `ListReconciler#reorder_nodes` depends on this semantics —
  # without it, reordering produces wrong positions.
  class LiveChildren
    def initialize(element)
      @element = element
    end

    def __js_get__(key)
      if key == "length"
        current.size
      elsif (idx = Integer(key, exception: false))
        current[idx]
      end
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(_method, _args)
      nil
    end

    # Used by host-side Ruby callers that want to iterate; the
    # bridge path goes through `__js_get__`.
    include Enumerable
    def each(&blk)
      current.each(&blk)
    end

    def size
      current.size
    end
    alias length size

    def [](idx)
      current[idx]
    end

    private

    def current
      @element.__node__.element_children.each_with_object([]) do |node, out|
        wrapped = @element.document.wrap_node(node)
        out << wrapped if wrapped
      end
    end
  end

  class ClassList
    def initialize(element)
      @element = element
    end

    def __js_call__(method, args)
      case method
      when "add"
        update_tokens { |tokens| tokens | normalize_tokens(args) }
        nil
      when "remove"
        update_tokens { |tokens| tokens - normalize_tokens(args) }
        nil
      when "contains"
        class_tokens.include?(args[0].to_s)
      when "toggle"
        toggle(args[0], args[1])
      else
        nil
      end
    end

    private

    def toggle(token, force)
      name = token.to_s
      present = class_tokens.include?(name)
      if force.nil?
        desired = !present
      else
        desired = !!force
      end

      update_tokens do |tokens|
        desired ? (tokens | [name]) : (tokens - [name])
      end
      desired
    end

    def normalize_tokens(args)
      args.map(&:to_s).reject(&:empty?)
    end

    def class_tokens
      raw = @element.__node__["class"].to_s
      raw.split(/\s+/).reject(&:empty?)
    end

    def update_tokens
      tokens = yield(class_tokens)
      if tokens.empty?
        @element.remove_attribute("class") if @element.__node__.key?("class")
      else
        @element.set_attribute("class", tokens.join(" "))
      end
    end
  end

  # `Element#dataset` proxy. `el.dataset.fooBar` reads / writes
  # `data-foo-bar` per the HTMLOrForeignElement.dataset spec
  # (camelCase ↔ kebab-case round-trip).
  class DatasetMap
    def initialize(element)
      @element = element
    end

    def __js_get__(key)
      @element.__node__[attr_name(key)]
    end

    def __js_set__(key, value)
      @element.set_attribute(attr_name(key), value.to_s)
      nil
    end

    def __js_call__(_method, _args)
      nil
    end

    private

    def attr_name(key)
      "data-#{key.to_s.gsub(/[A-Z]/) { |m| "-#{m.downcase}" }}"
    end
  end

  # Stub `DOMRect` for `getBoundingClientRect` — no layout engine,
  # so all values are 0. Lilac code that uses these for *relative*
  # positioning sees zeroed values; absolute layout assertions need
  # the real browser.
  class DOMRect
    def initialize(x: 0, y: 0, width: 0, height: 0)
      @x = x
      @y = y
      @width = width
      @height = height
    end

    def __js_get__(key)
      case key
      when "x", "left"   then @x
      when "y", "top"    then @y
      when "width"       then @width
      when "height"      then @height
      when "right"       then @x + @width
      when "bottom"      then @y + @height
      end
    end

    def js_null?
      false
    end
  end

  class StyleDeclaration
    include Enumerable

    def initialize(element)
      @element = element
    end

    # CSSStyleDeclaration interface: cssText round-trips the full
    # `style` attribute. Setter parses semicolon-separated entries.
    def css_text
      properties.map { |k, v| "#{k}:#{v}" }.join(";")
    end

    def css_text=(value)
      props = {}
      value.to_s.split(";").each do |entry|
        key, val = entry.split(":", 2)
        next unless key && val

        props[key.strip] = val.strip
      end
      write_properties(props)
    end

    def length
      properties.size
    end

    # `style[0]` returns the property name at that index (matches
    # `style.item(i)` in real DOM). String key form (`style["color"]`)
    # is a convenience shortcut for `getPropertyValue`.
    def [](key)
      if key.is_a?(Integer)
        properties.keys[key]
      else
        properties[key.to_s]
      end
    end

    def []=(name, value)
      set_property(name, value)
    end

    def each(&blk)
      properties.keys.each(&blk)
    end

    # camelCase JS property accessors → kebab-case CSS property name.
    # `style.backgroundColor = "red"` becomes `background-color: red`.
    def method_missing(name, *args)
      key = method_to_css_name(name)
      if name.to_s.end_with?("=")
        set_property(key, args.first)
      elsif properties.key?(key)
        properties[key]
      else
        ""
      end
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    def __js_get__(key)
      case key
      when "cssText"
        css_text
      when "length"
        length
      else
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          self[key.to_i]
        else
          properties[method_to_css_name(key)]
        end
      end
    end

    def __js_set__(key, value)
      case key
      when "cssText"
        self.css_text = value
      else
        set_property(method_to_css_name(key), value)
      end
      nil
    end

    def __js_call__(method, args)
      case method
      when "setProperty"
        set_property(args[0], args[1])
      when "removeProperty"
        remove_property(args[0])
      when "getPropertyValue"
        properties[args[0].to_s]
      when "item"
        properties.keys[args[0].to_i]
      else
        nil
      end
    end

    private

    def method_to_css_name(name)
      s = name.to_s.sub(/=\z/, "")
      # snake_case (Ruby idiomatic) → kebab; camelCase (JS idiomatic) → kebab.
      s.include?("_") ? s.tr("_", "-") : s.gsub(/[A-Z]/) { |m| "-#{m.downcase}" }
    end

    def set_property(name, value)
      key = name.to_s
      props = properties
      if value.nil? || value.to_s.empty?
        props.delete(key)
      else
        props[key] = value.to_s
      end
      write_properties(props)
      nil
    end

    def remove_property(name)
      key = name.to_s
      props = properties
      removed = props.delete(key)
      write_properties(props)
      removed
    end

    def properties
      raw = @element.__node__["style"].to_s
      raw.split(";").each_with_object({}) do |entry, out|
        key, value = entry.split(":", 2)
        next unless key && value

        out[key.strip] = value.strip
      end
    end

    def write_properties(props)
      if props.empty?
        @element.remove_attribute("style") if @element.__node__.key?("style")
      else
        @element.set_attribute("style", props.map { |k, v| "#{k}:#{v}" }.join(";"))
      end
    end
  end

  class Element
    include EventTarget
    include Node

    attr_reader :__node__, :document

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
      @class_list = ClassList.new(self)
      @style = StyleDeclaration.new(self)
      @dataset = DatasetMap.new(self)
      # `LiveChildren` re-evaluates the child list on every property
      # access so callers that capture `el[:children]` once see DOM
      # mutations made between iterations (required by Lilac's
      # ListReconciler#reorder_nodes — it relies on browser DOM's
      # live HTMLCollection semantics to detect already-positioned
      # nodes).
      @live_children = LiveChildren.new(self)
    end

    # ----- Public Ruby API (snake_case) -----
    #
    # Mirrors HTMLElement DOM properties / methods in idiomatic Ruby
    # form. The bridge protocol (`__js_get__` / `__js_call__`) routes
    # camelCase JS names through these same accessors, so any fix here
    # is visible in both views.

    def text_content
      @__node__.text
    end

    def text_content=(value)
      __js_set__("textContent", value)
    end

    def inner_html
      __js_get__("innerHTML")
    end

    def inner_html=(value)
      __js_set__("innerHTML", value)
    end

    def tag_name
      @__node__.name.upcase
    end

    def id
      @__node__["id"].to_s
    end

    def id=(value)
      set_attribute("id", value.to_s)
    end

    def class_name
      @__node__["class"].to_s
    end

    def class_name=(value)
      set_attribute("class", value.to_s)
    end

    def class_list
      @class_list
    end

    def style
      @style
    end

    def dataset
      @dataset
    end

    def children
      @live_children
    end

    def parent_element
      @document.wrap_node(@__node__.parent) if @__node__.parent&.element?
    end
    alias parent parent_element

    def parent_node
      @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    def first_element_child
      @document.wrap_node(@__node__.element_children.first)
    end

    def last_element_child
      @document.wrap_node(@__node__.element_children.last)
    end

    def first_child
      @document.wrap_node(@__node__.children.first)
    end

    def last_child
      @document.wrap_node(@__node__.children.last)
    end

    def child_element_count
      @__node__.element_children.size
    end

    def child_nodes
      @__node__.children.map { |n| @document.wrap_node(n) }.compact
    end

    def has_child_nodes?
      @__node__.children.any?
    end

    def has_attributes?
      @__node__.attribute_nodes.any?
    end

    def next_sibling
      @__node__.next && @document.wrap_node(@__node__.next)
    end

    def previous_sibling
      @__node__.previous && @document.wrap_node(@__node__.previous)
    end

    def next_element_sibling
      node = @__node__.next
      node = node.next while node && !node.element?
      node && @document.wrap_node(node)
    end

    def previous_element_sibling
      node = @__node__.previous
      node = node.previous while node && !node.element?
      node && @document.wrap_node(node)
    end

    # Outer HTML — serializes this element and its subtree. Setter
    # replaces this element in its parent with the parsed fragment.
    def outer_html
      @__node__.to_html
    end

    def outer_html=(html)
      parent = @__node__.parent
      return unless parent

      fragment = Parser.fragment(html.to_s, owner_doc: @__node__.document)
      anchor = @__node__.next_sibling
      removed = @__node__
      new_nodes = fragment.children.to_a
      @__node__.unlink
      if anchor
        new_nodes.reverse_each { |n| anchor.add_previous_sibling(n) }
      else
        new_nodes.each { |n| parent.add_child(n) }
      end
      @document.notify_child_list_mutation(target_node: parent, added_nodes: new_nodes, removed_nodes: [removed])
    end

    # `el.contains(other)` — true if `other` is `el` itself or any
    # descendant. Per spec, returns false for null/non-Node.
    def contains?(other)
      return false unless other.respond_to?(:__node__)

      other_node = other.__node__
      return true if other_node == @__node__

      ancestor = other_node.respond_to?(:parent) ? other_node.parent : nil
      while ancestor && !ancestor.is_a?(Nokogiri::XML::Document)
        return true if ancestor == @__node__

        ancestor = ancestor.respond_to?(:parent) ? ancestor.parent : nil
      end
      false
    end

    # `el.getRootNode()` — returns the topmost ancestor (document,
    # fragment, or self if detached). Walks until we hit a node whose
    # parent is the Nokogiri Document (i.e. not an element/fragment).
    def root_node
      current = @__node__
      loop do
        parent = current.respond_to?(:parent) ? current.parent : nil
        break unless parent
        break if parent.is_a?(Nokogiri::XML::Document)

        current = parent
      end
      @document.wrap_node(current) || @document
    end

    # Merge adjacent text node siblings and drop empty text nodes.
    def normalize
      @__node__.traverse do |node|
        next unless node.text?
        next if node.parent.nil?

        if node.content == "" && node.parent
          node.unlink
        elsif node.next && node.next.text?
          node.content = node.content + node.next.content
          node.next.unlink
        end
      end
      nil
    end

    def toggle_attribute(name, force = nil)
      key = name.to_s.downcase
      present = @__node__.key?(key)
      desired = force.nil? ? !present : !!force
      if desired
        set_attribute(key, "") unless present
        true
      else
        remove_attribute(key) if present
        false
      end
    end

    def matches?(selector)
      return false if selector.nil? || selector.to_s.empty?

      # `:scope` pseudo — match against this element itself.
      sel = selector.to_s.gsub(":scope", "*:nth-last-child(n)")
      matches_selector?(@__node__, sel)
    end

    def get_elements_by_class_name(name)
      tokens = name.to_s.split(/\s+/).reject(&:empty?)
      return NodeList.new if tokens.empty?

      selector = tokens.map { |t| ".#{t}" }.join("")
      NodeList.new(@__node__.css(selector).map { |n| @document.wrap_node(n) }.compact)
    end

    def get_elements_by_tag_name(name)
      n = name.to_s.downcase
      return NodeList.new(@__node__.css("*").map { |x| @document.wrap_node(x) }.compact) if n == "*"

      NodeList.new(@__node__.css(n).map { |x| @document.wrap_node(x) }.compact)
    end

    # NamedNodeMap of attributes. Lazily allocated and re-used so
    # `el.attributes === el.attributes` and `attr.ownerElement === el`.
    def attributes
      @attributes ||= NamedNodeMap.new(self)
    end

    def get_attribute_node(name)
      attributes.get_named_item(name)
    end

    def set_attribute_node(attr)
      attributes.set_named_item(attr)
    end

    def remove_attribute_node(attr)
      return nil unless attr.respond_to?(:name)

      attributes.remove_named_item(attr.name)
    end

    # HTML namespace constants — most HTML elements live in xhtml ns.
    def namespace_uri
      ns = @__node__.namespace
      ns ? ns.href : "http://www.w3.org/1999/xhtml"
    end

    def local_name
      @__node__.name.downcase
    end

    # `slot` and `role` are simple reflected string attributes —
    # added as named accessors for happy-dom test parity.
    def slot
      @__node__["slot"].to_s
    end

    def slot=(value)
      set_attribute("slot", value.to_s)
    end

    def role
      @__node__["role"].to_s
    end

    def role=(value)
      set_attribute("role", value.to_s)
    end

    # `baseURI` resolves to the document's location.href. Mirrors the
    # behavior `Node.baseURI` exhibits without `<base href>` overrides.
    def base_uri
      win = @document.default_view
      win&.location ? win.location.href : ""
    end

    # `focus()` / `blur()` — Dommy has no layout / real focus, but
    # tests rely on `document.activeElement` updating. Track the most
    # recently focused element on the document.
    def focus
      @document.__set_active_element__(self)
      nil
    end

    def blur
      @document.__set_active_element__(nil)
      nil
    end

    # `el.attachShadow({ mode: "open" | "closed" })` — creates and
    # attaches a ShadowRoot. The shadow tree lives in its own
    # Nokogiri fragment and is invisible to the outer querySelector /
    # children chain. Throws if a shadow is already attached.
    def attach_shadow(options = nil)
      raise "Shadow root already attached" if @__shadow_root

      opts = options.is_a?(Hash) ? options : {}
      mode = (opts["mode"] || opts[:mode] || "open").to_s
      raise ArgumentError, "mode must be 'open' or 'closed'" unless %w[open closed].include?(mode)

      @__shadow_root = ShadowRoot.new(
        self,
        mode: mode,
        delegates_focus: opts["delegatesFocus"] || opts[:delegatesFocus] || false,
        slot_assignment: opts["slotAssignment"] || opts[:slotAssignment] || "named"
      )
      @__shadow_root
    end

    # `el.shadowRoot` — returns the attached ShadowRoot only when
    # mode is "open"; closed shadows are hidden from external code.
    def shadow_root
      return nil unless @__shadow_root
      return nil if @__shadow_root.mode == "closed"

      @__shadow_root
    end

    # Internal — gives access to the shadow root regardless of mode.
    # Used by event composition / `composedPath()`.
    def __shadow_root__
      @__shadow_root
    end

    # `el.insertAdjacentElement(position, element)` — DOM spec positions:
    # "beforebegin", "afterbegin", "beforeend", "afterend". Returns the
    # inserted element or nil if position has no anchor (root cases).
    def insert_adjacent_element(position, element)
      return nil unless element.respond_to?(:__node__)

      case position.to_s
      when "beforebegin"
        return nil unless @__node__.parent

        node = detach_for_insert(element)
        @__node__.add_previous_sibling(node)
        @document.notify_child_list_mutation(target_node: @__node__.parent, added_nodes: [node], removed_nodes: [])
      when "afterbegin"
        node = detach_for_insert(element)
        first = @__node__.children.first
        first ? first.add_previous_sibling(node) : @__node__.add_child(node)
        @document.notify_child_list_mutation(target_node: @__node__, added_nodes: [node], removed_nodes: [])
      when "beforeend"
        node = detach_for_insert(element)
        @__node__.add_child(node)
        @document.notify_child_list_mutation(target_node: @__node__, added_nodes: [node], removed_nodes: [])
      when "afterend"
        return nil unless @__node__.parent

        node = detach_for_insert(element)
        @__node__.add_next_sibling(node)
        @document.notify_child_list_mutation(target_node: @__node__.parent, added_nodes: [node], removed_nodes: [])
      else
        return nil
      end
      element
    end

    def insert_adjacent_html(position, html)
      fragment = Parser.fragment(html.to_s, owner_doc: @__node__.document)
      nodes = fragment.children.to_a
      case position.to_s
      when "beforebegin"
        return nil unless @__node__.parent

        nodes.reverse_each { |n| @__node__.add_previous_sibling(n) }
        @document.notify_child_list_mutation(target_node: @__node__.parent, added_nodes: nodes, removed_nodes: [])
      when "afterbegin"
        first = @__node__.children.first
        if first
          nodes.reverse_each { |n| first.add_previous_sibling(n) }
        else
          nodes.each { |n| @__node__.add_child(n) }
        end
        @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      when "beforeend"
        nodes.each { |n| @__node__.add_child(n) }
        @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      when "afterend"
        return nil unless @__node__.parent

        nodes.reverse_each { |n| @__node__.add_next_sibling(n) }
        @document.notify_child_list_mutation(target_node: @__node__.parent, added_nodes: nodes, removed_nodes: [])
      end
      nil
    end

    def insert_adjacent_text(position, text)
      return nil if text.to_s.empty?

      insert_adjacent_element(position, @document.create_text_node(text.to_s))
    end

    # Convenience alias matching the DOM idiom `String(el)` → outerHTML.
    def to_s
      outer_html
    end

    # Node type / NodeFilter bitmask constants — DOM Level 3 says these
    # are exposed on both the constructor and every instance. Defined
    # at the bottom of the class so subclasses inherit them too.
    ELEMENT_NODE                = 1
    ATTRIBUTE_NODE              = 2
    TEXT_NODE                   = 3
    CDATA_SECTION_NODE          = 4
    PROCESSING_INSTRUCTION_NODE = 7
    COMMENT_NODE                = 8
    DOCUMENT_NODE               = 9
    DOCUMENT_TYPE_NODE          = 10
    DOCUMENT_FRAGMENT_NODE      = 11

    DOCUMENT_POSITION_DISCONNECTED            = 0x01
    DOCUMENT_POSITION_PRECEDING               = 0x02
    DOCUMENT_POSITION_FOLLOWING               = 0x04
    DOCUMENT_POSITION_CONTAINS                = 0x08
    DOCUMENT_POSITION_CONTAINED_BY            = 0x10
    DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = 0x20

    # Standard DOM compareDocumentPosition. Returns 0 for self, a
    # CONTAINS/CONTAINED_BY bitmask for ancestor/descendant pairs, or
    # PRECEDING/FOLLOWING for siblings (and DISCONNECTED for unrelated
    # nodes).
    def compare_document_position(other)
      return 0 if equal?(other)
      return DOCUMENT_POSITION_DISCONNECTED unless other.respond_to?(:__node__)

      self_node  = @__node__
      other_node = other.__node__

      self_ancestors  = ancestor_chain(self_node)
      other_ancestors = ancestor_chain(other_node)

      common = nil
      self_ancestors.each do |a|
        if other_ancestors.include?(a)
          common = a
          break
        end
      end
      return DOCUMENT_POSITION_DISCONNECTED |
             DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC |
             DOCUMENT_POSITION_PRECEDING unless common

      if common == self_node
        return DOCUMENT_POSITION_CONTAINED_BY | DOCUMENT_POSITION_FOLLOWING
      elsif common == other_node
        return DOCUMENT_POSITION_CONTAINS | DOCUMENT_POSITION_PRECEDING
      end

      # Sibling-of-some-level case: compare the two branch points
      # under the common ancestor.
      self_branch  = branch_under(common, self_ancestors)
      other_branch = branch_under(common, other_ancestors)
      common.children.each do |child|
        if child == self_branch
          return DOCUMENT_POSITION_FOLLOWING
        elsif child == other_branch
          return DOCUMENT_POSITION_PRECEDING
        end
      end
      DOCUMENT_POSITION_DISCONNECTED
    end

    # `Node.isSameNode(other)` — strict reference identity. The DOM
    # spec deprecates this in favor of `===`, but linkedom-style
    # tests still call it.
    def same_node?(other)
      equal?(other)
    end

    # Structural equality — same nodeType, same tagName, same attribute
    # set, and recursively-equal children. Used by linkedom test
    # suite and standard DOM Node.isEqualNode.
    def equal_node?(other)
      return false unless other.is_a?(Element)
      return false unless @__node__.name == other.__node__.name
      return false unless attribute_signature == other.send(:attribute_signature)
      return false unless @__node__.children.size == other.__node__.children.size

      @__node__.children.zip(other.__node__.children).all? do |a, b|
        wa = @document.wrap_node(a)
        wb = @document.wrap_node(b)
        wa.respond_to?(:equal_node?) ? wa.equal_node?(wb) : a.content == b.content
      end
    end

    private

    def ancestor_chain(node)
      chain = [node]
      current = node
      while current.respond_to?(:parent) && current.parent && !current.parent.is_a?(Nokogiri::XML::Document)
        chain << current.parent
        current = current.parent
      end
      chain
    end

    def branch_under(common, chain)
      # Walk back along `chain` to find the entry whose parent is `common`.
      chain.each_with_index do |node, i|
        return node if i.zero? && node == common
        return node if node.respond_to?(:parent) && node.parent == common
      end
      nil
    end

    def attribute_signature
      @__node__.attribute_nodes.map { |a| [a.name, a.value] }.sort
    end

    public

    def remove
      __js_call__("remove", [])
    end

    # ParentNode mixin methods — append / prepend / replaceChildren
    # take a mix of Node and String args (strings become text nodes).

    def append(*args)
      append_nodes(args)
    end

    def prepend(*args)
      prepend_nodes(args)
    end

    def replace_children(*args)
      removed = @__node__.children.to_a
      removed.each(&:unlink)
      nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
      nodes.each { |n| @__node__.add_child(n) }
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: removed)
      nil
    end

    # ChildNode mixin — before / after / replaceWith with mixed args.

    def before(*args)
      insert_adjacent(:before, args)
    end

    def after(*args)
      insert_adjacent(:after, args)
    end

    def replace_with_nodes(*args)
      replace_with(args)
    end

    # `getInnerHTML()` — happy-dom alias for the `innerHTML` getter.
    # Real browsers add a `{ includeShadowRoots }` option which we
    # ignore (no Shadow DOM in Dommy).
    def get_inner_html(_options = nil)
      inner_html
    end

    def get_html(_options = nil)
      inner_html
    end

    def click
      __js_call__("click", [])
    end

    # Ruby block-style listener (in addition to the (type, callable,
    # options) form inherited from EventTarget). Returns the resolved
    # listener so callers can pass it back to remove_event_listener.
    def on(type, &block)
      add_event_listener(type, block)
      block
    end

    # `el[:foo]` / `el[:foo] = ...` shortcut mirroring mruby-wasm-js
    # style. Useful when porting browser-side code to CRuby tests.
    def [](key)
      __js_get__(key.to_s)
    end

    def []=(key, value)
      __js_set__(key.to_s, value)
    end

    def __js_get__(key)
      case key
      when "nodeType"
        1
      when "isConnected"
        !@__node__.document.nil? && !@__node__.ancestors("html").empty?
      when "children"
        @live_children
      when "firstElementChild"
        @document.wrap_node(@__node__.element_children.first)
      when "parentElement", "parent"
        wrap_parent(@__node__.parent)
      when "parentNode"
        # `parentNode` is broader than `parentElement` — includes
        # DocumentFragment / Document parents too. Lilac's ListReconciler
        # uses this to find the host before calling replaceChild.
        @__node__.parent && @document.wrap_node(@__node__.parent)
      when "textContent"
        @__node__.text
      when "innerHTML"
        if @__node__.name == "template"
          @document.template_content_inner_html(self)
        else
          @__node__.inner_html
        end
      when "tagName"
        @__node__.name.upcase
      when "classList"
        @class_list
      when "style"
        @style
      when "dataset"
        @dataset
      when "content"
        template_content
      when "className"
        # DOM reflects the `class` attribute as the `className` string
        # property (space-separated tokens, "" when absent).
        @__node__["class"].to_s
      when "id"
        @__node__["id"].to_s
      when "hidden", "disabled", "checked", "readOnly", "multiple", "required"
        # Boolean reflected properties — true iff the matching HTML
        # attribute is present. Real DOM normalizes attribute names to
        # lowercase, mapped here too (e.g. `readOnly` ↔ `readonly`).
        @__node__.key?(reflected_attr_name(key))
      when "value"
        # For form elements `value` is a property that defaults to the
        # `value` attribute. We don't model the property/attribute
        # split here — both reads and writes go through the attribute.
        @__node__["value"].to_s
      when "href"
        anchor_href
      when "attributes"
        attributes
      when "namespaceURI"
        namespace_uri
      when "localName"
        local_name
      when "nodeName"
        @__node__.name.upcase
      when "slot"
        slot
      when "role"
        role
      when "baseURI"
        base_uri
      when "shadowRoot"
        shadow_root
      else
        # `el.onXxx` event handler property — returns the registered
        # callback (if any), or nil.
        if key.start_with?("on") && key.length > 2
          @on_handlers&.[](event_name_from_on(key))
        end
      end
    end

    # Anchor / area `href` IDL attribute reflects the attribute resolved
    # against the document base URL (browser semantics). Routers rely on
    # this to compare origins and detect external links.
    def anchor_href
      raw = @__node__["href"]
      return "" if raw.nil?

      win = @document.default_view
      base = win&.location ? win.location.href : ""
      URI.join(base, raw.to_s).to_s
    rescue URI::InvalidURIError, ArgumentError
      raw.to_s
    end

    # Map a JS boolean property name to its underlying HTML attribute.
    # HTML attribute names are lowercase; the DOM property may be
    # camelCase (`readOnly` → `readonly`).
    def reflected_attr_name(key)
      { "readOnly" => "readonly" }.fetch(key, key)
    end

    def __js_set__(key, value)
      case key
      when "textContent"
        @__node__.content = value.to_s
      when "innerHTML"
        removed = @__node__.children.to_a
        if @__node__.name == "template"
          # `<template>` content is invisible to selectors / Lilac.start
          # scans in real DOM (it lives in a separate DocumentFragment
          # exposed via `[:content]`). Mirror that here so child
          # `<span data-ref>` placeholders don't pollute spec queries.
          @document.attach_template_content(self, value.to_s)
        else
          @__node__.inner_html = value.to_s
          @document.migrate_template_descendants(@__node__)
        end
        @document.notify_child_list_mutation(
          target_node: @__node__,
          added_nodes: @__node__.children.to_a,
          removed_nodes: removed
        )
      when "hidden", "disabled", "checked", "readOnly", "multiple", "required"
        # Boolean reflected property — funnel through set_attribute /
        # remove_attribute so MutationObserver attribute records fire.
        name = reflected_attr_name(key)
        if value
          set_attribute(name, "")
        elsif @__node__.key?(name)
          remove_attribute(name)
        end
      when "className"
        set_attribute("class", value.to_s)
      when "id"
        set_attribute("id", value.to_s)
      when "value"
        set_attribute("value", value.to_s)
      when "slot"
        set_attribute("slot", value.to_s)
      when "role"
        set_attribute("role", value.to_s)
      else
        # `el.onXxx = fn` registers fn as a single named handler.
        # Setting to nil removes it. Mirrors HTMLElement IDL.
        if key.start_with?("on") && key.length > 2
          set_on_handler(event_name_from_on(key), value)
        else
          nil
        end
      end
    end

    private

    def event_name_from_on(key)
      key.to_s.sub(/\Aon/, "").downcase
    end

    def set_on_handler(event_name, value)
      @on_handlers ||= {}
      previous = @on_handlers[event_name]
      remove_event_listener(event_name, previous) if previous
      if value
        add_event_listener(event_name, value)
        @on_handlers[event_name] = value
      else
        @on_handlers.delete(event_name)
      end
    end

    public

    def __js_call__(method, args)
      case method
      when "getAttribute"
        get_attribute(args[0])
      when "setAttribute"
        set_attribute(args[0], args[1])
      when "hasAttribute"
        has_attribute?(args[0])
      when "removeAttribute"
        remove_attribute(args[0])
      when "getAttributeNames"
        @__node__.attribute_nodes.map(&:name)
      when "closest"
        closest(args[0])
      when "querySelector"
        query_selector(args[0])
      when "querySelectorAll"
        query_selector_all(args[0])
      when "getElementsByClassName"
        get_elements_by_class_name(args[0])
      when "getElementsByTagName"
        get_elements_by_tag_name(args[0])
      when "insertAdjacentElement"
        insert_adjacent_element(args[0], args[1])
      when "insertAdjacentHTML"
        insert_adjacent_html(args[0], args[1])
      when "insertAdjacentText"
        insert_adjacent_text(args[0], args[1])
      when "toggleAttribute"
        toggle_attribute(args[0], args[1])
      when "matches"
        matches?(args[0])
      when "toString"
        to_s
      when "getAttributeNode"
        get_attribute_node(args[0])
      when "setAttributeNode"
        set_attribute_node(args[0])
      when "removeAttributeNode"
        remove_attribute_node(args[0])
      when "focus"
        focus
      when "blur"
        blur
      when "attachShadow"
        attach_shadow(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "appendChild"
        append_child(args[0])
      when "insertBefore"
        insert_before(args[0], args[1])
      when "removeChild"
        remove_child(args[0])
      when "replaceChild"
        replace_child(args[0], args[1])
      when "cloneNode"
        clone_node(args[0])
      when "append"
        append_nodes(args)
      when "prepend"
        prepend_nodes(args)
      when "replaceChildren"
        replace_children(*args)
      when "before"
        insert_adjacent(:before, args)
      when "after"
        insert_adjacent(:after, args)
      when "getInnerHTML", "getHTML"
        inner_html
      when "remove"
        parent = @__node__.parent
        @__node__.unlink
        @document.notify_child_list_mutation(target_node: parent, added_nodes: [], removed_nodes: [@__node__]) if parent
        nil
      when "replaceWith"
        replace_with(args)
      when "click"
        dispatch_event(MouseEvent.new("click", "bubbles" => true, "cancelable" => true, "button" => 0))
      when "getBoundingClientRect"
        DOMRect.new
      else
        nil
      end
    end

    private

    def element_children
      @__node__.element_children.each_with_object([]) do |node, out|
        wrapped = @document.wrap_node(node)
        out << wrapped if wrapped
      end
    end

    def wrap_parent(node)
      @document.wrap_node(node)
    end

    def __event_parent__
      parent_node = @__node__.parent
      # If our Nokogiri parent is a shadow tree's backing fragment,
      # the bubble path's next stop is the ShadowRoot itself — not
      # the bare Fragment wrapper. The ShadowRoot's __event_parent__
      # will return nil (composed events route to host explicitly).
      if parent_node.is_a?(Nokogiri::XML::DocumentFragment)
        sr = @document.__shadow_root_for_fragment__(parent_node)
        return sr if sr
      end

      parent = wrap_parent(parent_node)
      parent || @document
    end

    def template_content
      return nil unless @__node__.name == "template"

      @document.template_content_fragment(self)
    end

    # HTML attribute names are case-insensitive — browser DOM stores
    # them in lowercase regardless of the case passed to setAttribute.
    # Matches that behavior so callers using `"SRC"` / `"Action"` /
    # etc. interoperate with `getAttribute("src")` round-trips.
    def get_attribute(name)
      return nil if name.nil?

      @__node__[name.to_s.downcase]
    end

    def set_attribute(name, value)
      return nil if name.nil?

      key = name.to_s.downcase
      old = @__node__[key]
      @__node__[key] = value.to_s
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: key, old_value: old)
      nil
    end

    def has_attribute?(name)
      return false if name.nil?

      @__node__.key?(name.to_s.downcase)
    end

    def remove_attribute(name)
      return nil if name.nil?

      key = name.to_s.downcase
      return nil unless @__node__.key?(key)

      old = @__node__[key]
      @__node__.remove_attribute(key)
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: key, old_value: old)
      nil
    end

    def closest(selector)
      return nil if selector.nil? || selector.to_s.empty?

      node = @__node__
      while node&.element?
        return @document.wrap_node(node) if matches_selector?(node, selector.to_s)

        node = node.parent
      end
      nil
    end

    def query_selector(selector)
      return nil if selector.nil? || selector.to_s.empty?

      @document.wrap_node(@__node__.at_css(selector.to_s))
    end

    def query_selector_all(selector)
      return NodeList.new if selector.nil? || selector.to_s.empty?

      NodeList.new(@__node__.css(selector.to_s).map { |node| @document.wrap_node(node) }.compact)
    end

    def append_child(child)
      nodes = detach_dom_nodes(child)
      append_dom_nodes(nodes)
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      child
    end

    def insert_before(child, reference)
      nodes = detach_dom_nodes(child)
      if reference.nil?
        append_dom_nodes(nodes)
      else
        ref_node = unwrap_dom_node(reference)
        if ref_node&.parent != @__node__
          append_dom_nodes(nodes)
        else
          nodes.reverse_each { |node| ref_node.add_previous_sibling(node) }
        end
      end
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      child
    end

    def remove_child(child)
      node = unwrap_dom_node(child)
      return nil unless node&.parent == @__node__

      node.unlink
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: [], removed_nodes: [node])
      child
    end

    # `node.replaceChild(newChild, oldChild)` — required by Lilac's
    # ListReconciler#apply_string for in-place item updates. Inserts
    # newChild where oldChild was, then unlinks oldChild. Notifies
    # MutationObserver of both changes in one record so observers see
    # the swap atomically.
    def replace_child(new_child, old_child)
      old_node = unwrap_dom_node(old_child)
      return nil unless old_node&.parent == @__node__

      new_nodes = detach_dom_nodes(new_child)
      new_nodes.reverse_each { |node| old_node.add_previous_sibling(node) }
      old_node.unlink
      @document.notify_child_list_mutation(
        target_node: @__node__,
        added_nodes: new_nodes,
        removed_nodes: [old_node]
      )
      old_child
    end

    def clone_node(deep_arg)
      deep = !!deep_arg
      if deep
        @document.wrap_node(Parser.fragment(@__node__.to_html, owner_doc: @document.nokogiri_doc).children.find(&:element?))
      else
        clone = @document.create_element(@__node__.name)
        @__node__.attribute_nodes.each do |attr|
          clone.__js_call__("setAttribute", [attr.name, attr.value])
        end
        clone
      end
    end

    def append_nodes(args)
      nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
      append_dom_nodes(nodes)
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      nil
    end

    def prepend_nodes(args)
      nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
      anchor = @__node__.children.first
      if anchor
        nodes.reverse_each { |node| anchor.add_previous_sibling(node) }
      else
        append_dom_nodes(nodes)
      end
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: nodes, removed_nodes: [])
      nil
    end

    def insert_adjacent(side, args)
      parent = @__node__.parent
      return nil unless parent

      nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
      case side
      when :before
        nodes.reverse_each { |node| @__node__.add_previous_sibling(node) }
      when :after
        anchor = @__node__.next_sibling
        if anchor
          nodes.reverse_each { |node| anchor.add_previous_sibling(node) }
        else
          nodes.each { |node| parent.add_child(node) }
        end
      end
      @document.notify_child_list_mutation(target_node: parent, added_nodes: nodes, removed_nodes: [])
      nil
    end

    def replace_with(args)
      parent = @__node__.parent
      return nil unless parent

      nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
      removed = @__node__
      anchor = @__node__.next_sibling
      @__node__.unlink
      if anchor
        nodes.reverse_each { |node| anchor.add_previous_sibling(node) }
      else
        nodes.each { |node| parent.add_child(node) }
      end
      @document.notify_child_list_mutation(target_node: parent, added_nodes: nodes, removed_nodes: [removed])
      nil
    end

    def append_dom_nodes(nodes)
      nodes.each { |node| @__node__.add_child(node) }
    end

    def detach_for_insert(value)
      detach_dom_nodes(value).first
    end

    def detach_dom_nodes(value)
      case value
      when Element, TextNode, CommentNode
        node = value.__node__
        node.unlink if node.parent
        [node]
      when Fragment
        value.extract_children
      when String
        [@document.create_text_node(value).__node__]
      else
        node = unwrap_dom_node(value)
        return [] unless node

        node.unlink if node.parent
        [node]
      end
    end

    def unwrap_dom_node(value)
      return value.__node__ if value.respond_to?(:__node__)

      nil
    end

    def matches_selector?(node, selector)
      if node.respond_to?(:matches?)
        node.matches?(selector)
      else
        node.document.css(selector).any? { |candidate| candidate == node }
      end
    end

    # Re-expose snake_case methods that the JS bridge dispatch routes
    # to. Defined as private originally so internal helpers (element_children,
    # detach_dom_nodes, etc.) stay encapsulated; CRuby users call these
    # as the public Ruby API.
    public :get_attribute, :set_attribute, :has_attribute?, :remove_attribute,
           :append_child, :insert_before, :remove_child, :replace_child,
           :clone_node, :query_selector, :query_selector_all, :closest
  end
end
