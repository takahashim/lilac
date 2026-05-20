# frozen_string_literal: true

require "uri"

require_relative "parser"

class MrubyWasm
  module Dom
    class Fragment
      attr_reader :__node__

      def initialize(document, nokogiri_node)
        @document = document
        @__node__ = nokogiri_node
      end

      def __js_get__(key)
        case key
        when "nodeType"
          11
        when "children"
          element_children
        when "firstElementChild"
          @document.wrap_node(@__node__.children.find(&:element?))
        when "textContent"
          @__node__.text
        else
          nil
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

      def element_children
        @__node__.element_children.each_with_object([]) do |node, out|
          wrapped = @document.wrap_node(node)
          out << wrapped if wrapped
        end
      end

      def query_selector(selector)
        return nil if selector.nil? || selector.to_s.empty?

        @document.wrap_node(@__node__.at_css(selector.to_s))
      end

      def query_selector_all(selector)
        return [] if selector.nil? || selector.to_s.empty?

        @__node__.css(selector.to_s).map { |node| @document.wrap_node(node) }.compact
      end
    end

    class TextNode
      attr_reader :__node__

      def initialize(document, nokogiri_node)
        @document = document
        @__node__ = nokogiri_node
      end

      def __js_get__(key)
        case key
        when "nodeType"
          3
        when "textContent"
          @__node__.text
        else
          nil
        end
      end

      def __js_set__(key, value)
        case key
        when "textContent"
          @__node__.content = value.to_s
        else
          nil
        end
      end

      def __js_call__(method, args)
        case method
        when "cloneNode"
          @document.create_text_node(args.empty? ? @__node__.text : @__node__.text)
        when "remove"
          @__node__.unlink
          nil
        else
          nil
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
          @element.__node__.remove_attribute("class")
        else
          @element.__node__["class"] = tokens.join(" ")
        end
      end
    end

    class StyleDeclaration
      def initialize(element)
        @element = element
      end

      def __js_call__(method, args)
        case method
        when "setProperty"
          set_property(args[0], args[1])
        when "removeProperty"
          remove_property(args[0])
        when "getPropertyValue"
          properties[args[0].to_s]
        else
          nil
        end
      end

      private

      def set_property(name, value)
        key = name.to_s
        props = properties
        props[key] = value.to_s
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
          @element.__node__.remove_attribute("style")
        else
          @element.__node__["style"] = props.map { |k, v| "#{k}: #{v}" }.join("; ")
        end
      end
    end

    # Session 2 covers the read-mostly Element/Node surface needed by
    # Lilac's tree walkers: attributes, text/html reads, parent/child
    # traversal, and `closest`.
    class Element
      include EventTarget

      attr_reader :__node__, :document

      def initialize(document, nokogiri_node)
        @document = document
        @__node__ = nokogiri_node
        @class_list = ClassList.new(self)
        @style = StyleDeclaration.new(self)
        # `LiveChildren` re-evaluates the child list on every property
        # access so callers that capture `el[:children]` once see DOM
        # mutations made between iterations (required by Lilac's
        # ListReconciler#reorder_nodes — it relies on browser DOM's
        # live HTMLCollection semantics to detect already-positioned
        # nodes).
        @live_children = LiveChildren.new(self)
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
        else
          nil
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
          # Boolean reflected property: truthy → attribute present,
          # falsy → attribute removed. Mirrors browser DOM semantics
          # for these reflected attrs.
          name = reflected_attr_name(key)
          if value
            @__node__[name] = ""
          else
            @__node__.remove_attribute(name)
          end
        when "className"
          @__node__["class"] = value.to_s
        when "id"
          @__node__["id"] = value.to_s
        when "value"
          @__node__["value"] = value.to_s
        else
          nil
        end
      end

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
        when "before"
          insert_adjacent(:before, args)
        when "after"
          insert_adjacent(:after, args)
        when "remove"
          parent = @__node__.parent
          @__node__.unlink
          @document.notify_child_list_mutation(target_node: parent, added_nodes: [], removed_nodes: [@__node__]) if parent
          nil
        when "replaceWith"
          replace_with(args)
        when "click"
          dispatch_event(MouseEvent.new("click", "bubbles" => true, "cancelable" => true, "button" => 0))
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
        parent = wrap_parent(@__node__.parent)
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

        @__node__[name.to_s.downcase] = value.to_s
        nil
      end

      def has_attribute?(name)
        return false if name.nil?

        @__node__.key?(name.to_s.downcase)
      end

      def remove_attribute(name)
        return nil if name.nil?

        @__node__.remove_attribute(name.to_s.downcase)
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
        return [] if selector.nil? || selector.to_s.empty?

        @__node__.css(selector.to_s).map { |node| @document.wrap_node(node) }.compact
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

      def detach_dom_nodes(value)
        case value
        when Element, TextNode
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
    end
  end
end
