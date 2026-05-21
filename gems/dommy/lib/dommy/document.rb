# frozen_string_literal: true

module Dommy
  # Stub DocumentType (`<!doctype html>`) — exposes `name` and `nodeType=10`.
  # Real browsers also expose `publicId` / `systemId` which we leave empty
  # since HTML5 doctypes don't carry those.
  class DocumentType
    include Node

    attr_reader :name

    def initialize(name)
      @name = name.to_s
    end

    def __js_get__(key)
      case key
      when "name"      then @name
      when "nodeType"  then 10
      when "publicId"  then ""
      when "systemId"  then ""
      end
    end
  end

  # `document` — the entry point for DOM construction and querying.
  # Wrapper caching keeps DOM identity stable across repeated
  # traversals (`body.children[0].parentElement`).
  class Document
    include EventTarget
    include Node

    attr_reader :body, :nokogiri_doc
    attr_accessor :default_view

    def initialize(host = nil)
      @host = host
      @node_wrappers = {}
      @observers = []
      # `<template>` content lives in a separate DocumentFragment in
      # real DOM — invisible to selectors. We mirror that by reparenting
      # any template's children into a fragment stored here, keyed by
      # the template element's Nokogiri object_id. The template
      # element itself becomes empty in the live tree.
      @template_contents = {}
      # In-memory cookie jar: name → value. Not persisted across VMs.
      # Real browsers track Path / Domain / Expires too; we mirror just
      # the simple `document.cookie` key=value; key=value semantics.
      @cookies = {}
      @nokogiri_doc = Nokogiri::HTML5("<!doctype html><html><head></head><body></body></html>")
      @body = wrap_node(@nokogiri_doc.at_css("body"))
    end

    # ----- Public Ruby API (snake_case) -----

    def title
      read_title
    end

    def title=(value)
      write_title(value.to_s)
    end

    def document_element
      wrap_node(@nokogiri_doc.at_css("html"))
    end

    def head
      wrap_node(@nokogiri_doc.at_css("head"))
    end

    # `document.URL` / `documentURI` — both return location.href in
    # real browsers (legacy aliases of the same field).
    def url
      view = @default_view
      view&.location ? view.location.href : ""
    end
    alias document_uri url

    def base_uri
      url
    end

    # `document.domain` — host portion of the URL. Real browsers
    # restrict cross-origin reads of this; we just return the bare host.
    def domain
      view = @default_view
      return "" unless view&.location

      view.location.__js_get__("hostname").to_s
    end

    # `document.referrer` — Dommy never has a referring page, so this
    # is always empty.
    def referrer
      ""
    end

    # Live `HTMLCollection`-ish helpers. Real browsers return live
    # collections; we return snapshot NodeList instances which is
    # sufficient for most test scenarios.
    def links
      NodeList.new(@nokogiri_doc.css("a[href], area[href]").map { |n| wrap_node(n) }.compact)
    end

    def forms
      NodeList.new(@nokogiri_doc.css("form").map { |n| wrap_node(n) }.compact)
    end

    def scripts
      NodeList.new(@nokogiri_doc.css("script").map { |n| wrap_node(n) }.compact)
    end

    def images
      NodeList.new(@nokogiri_doc.css("img").map { |n| wrap_node(n) }.compact)
    end

    # ParentNode mixin (operates on the document's element children —
    # in practice the `<html>` root).
    def children
      root = @nokogiri_doc.root
      root ? [wrap_node(root)].compact : []
    end

    def child_element_count
      children.size
    end

    def first_element_child
      wrap_node(@nokogiri_doc.root)
    end

    def last_element_child
      wrap_node(@nokogiri_doc.root)
    end

    # Currently-focused element (or body if none). Updated via
    # `el.focus()` / `el.blur()`.
    def active_element
      @active_element || @body
    end

    def __set_active_element__(el)
      @active_element = el
    end

    # Create a detached Attr. `setAttributeNode` attaches it to an
    # element.
    def create_attribute(name)
      Attr.new(name)
    end

    def create_attribute_ns(_namespace_uri, qualified_name)
      # Namespaced attrs are tracked via Nokogiri's `add_namespace_definition`
      # when actually set on an element. Detached form is the same Attr.
      Attr.new(qualified_name)
    end

    # `document.createTreeWalker(root, whatToShow?, filter?)` — stateful
    # tree traversal with sibling/parent navigation. `filter` may be a
    # Ruby Proc, a JS-bridge callable, or an object with
    # `accept_node` / `acceptNode`.
    def create_tree_walker(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      TreeWalker.new(root, what_to_show, filter)
    end

    # Copy a node from another document into this one. The returned
    # wrapper is owned by `this`. Per spec, the source node is left
    # in place. `deep: true` copies the entire subtree.
    def import_node(node, deep = false)
      return nil unless node.respond_to?(:__node__)

      copy = clone_into_doc(node.__node__, deep)
      wrap_node(copy)
    end

    # Move a node from another document into this one. The source
    # node is detached from its previous owner and its ownerDocument
    # becomes this. Returns the (possibly re-wrapped) node.
    def adopt_node(node)
      return nil unless node.respond_to?(:__node__)

      src = node.__node__
      src.unlink if src.parent
      moved = if src.document == @nokogiri_doc
                src
              else
                clone_into_doc(src, true)
              end
      wrap_node(moved)
    end

    # Legacy `document.createEvent("EventName")` factory. Returns an
    # Event subclass instance whose init still has to be called
    # (`event.initEvent(type, bubbles, cancelable)`). Matches the
    # mapping happy-dom and linkedom use.
    def create_event(type_name)
      name = type_name.to_s
      case name
      when "Event", "Events", "HTMLEvents"
        Event.new("")
      when "CustomEvent"
        CustomEvent.new("")
      when "MouseEvent", "MouseEvents"
        MouseEvent.new("")
      when "KeyboardEvent", "KeyboardEvents"
        KeyboardEvent.new("")
      else
        Event.new("")
      end
    end

    # Stubs for layout / focus / selection / execCommand APIs that
    # don't apply to a layout-less DOM. They exist so callers don't
    # hit NoMethodError; semantics are documented as no-op.

    def has_focus?
      true
    end
    alias has_focus has_focus?

    def get_selection
      nil
    end

    def element_from_point(_x, _y)
      nil
    end

    def query_command_supported(_command)
      false
    end

    # `document.createNodeIterator(root, whatToShow?, filter?)` —
    # flat depth-first iteration.
    def create_node_iterator(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      NodeIterator.new(root, what_to_show, filter)
    end

    # Minimal DocumentType — represents the `<!doctype html>` line.
    # Always present in HTML5 documents we parse, so we synthesize a
    # stub object whose only useful field is `name`. Tests just need
    # `nodeType == 10`.
    def doctype
      @doctype ||= DocumentType.new("html")
    end

    # `document.cookie` returns "k=v; k=v" formatted string of all
    # currently-set cookies. Setter parses a single Set-Cookie-style
    # entry (`"k=v; Path=/; Expires=…"`) and stores k=v only.
    def cookie
      @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
    end

    def cookie=(value)
      pair = value.to_s.split(";", 2).first.to_s.strip
      return if pair.empty?

      key, val = pair.split("=", 2)
      @cookies[key.to_s.strip] = val.to_s.strip if key
      nil
    end

    # Create a namespaced element. The host Nokogiri document doesn't
    # have a global namespace registry for HTML, so we attach the
    # namespace via add_namespace_definition. For SVG / MathML callers
    # this routes through fragment parsing which handles namespaces.
    def create_element_ns(namespace_uri, qualified_name)
      return nil if qualified_name.nil? || qualified_name.to_s.empty?

      el = Nokogiri::XML::Node.new(qualified_name.to_s, @nokogiri_doc)
      el.add_namespace_definition(nil, namespace_uri.to_s) if namespace_uri && !namespace_uri.to_s.empty?
      wrap_node(el)
    end

    def get_elements_by_tag_name(name)
      n = name.to_s.downcase
      return NodeList.new(@nokogiri_doc.css("*").map { |x| wrap_node(x) }.compact) if n == "*"

      NodeList.new(@nokogiri_doc.css(n).map { |x| wrap_node(x) }.compact)
    end

    def get_elements_by_name(name)
      NodeList.new(@nokogiri_doc.css("[name='#{name}']").map { |x| wrap_node(x) }.compact)
    end

    # `document.write(html)` — legacy API. Appends parsed nodes to the
    # body. Real browsers only re-stream the DOM during initial parse;
    # this stub is enough for tests that fire write() during teardown.
    def write(*args)
      html = args.join
      fragment = Parser.fragment(html, owner_doc: @nokogiri_doc)
      removed = []
      added = fragment.children.to_a
      added.each { |node| @body.__node__.add_child(node) }
      notify_child_list_mutation(target_node: @body.__node__, added_nodes: added, removed_nodes: removed)
      nil
    end

    # No-ops — real browsers reset the DOM on `open()` and flush
    # pending writes on `close()`. We don't model the parse pipeline.
    def open
      nil
    end

    def close
      nil
    end

    def [](key)
      __js_get__(key.to_s)
    end

    def []=(key, value)
      __js_set__(key.to_s, value)
    end

    # Create a Comment node. Wraps the Nokogiri comment so it flows
    # through the same wrap_node identity machinery as Element / TextNode.
    def create_comment(text)
      wrap_node(Nokogiri::XML::Comment.new(@nokogiri_doc, text.to_s))
    end

    # Create an empty DocumentFragment. Children can be appended via
    # the standard DOM tree APIs.
    def create_document_fragment
      wrap_node(@nokogiri_doc.fragment(""))
    end

    # Return all elements with the given class name (space-separated
    # tokens, one match suffices per token). Live HTMLCollection
    # semantics are not honored — returns a snapshot Array.
    def get_elements_by_class_name(name)
      tokens = name.to_s.split(/\s+/).reject(&:empty?)
      return NodeList.new if tokens.empty?

      selector = tokens.map { |t| ".#{t}" }.join("")
      NodeList.new(@nokogiri_doc.css(selector).map { |n| wrap_node(n) }.compact)
    end

    def __js_get__(key)
      case key
      when "body" then @body
      when "head" then head
      when "doctype" then doctype
      when "defaultView" then @default_view
      when "documentElement" then wrap_node(@nokogiri_doc.at_css("html"))
      when "title" then read_title
      when "cookie" then cookie
      when "nodeType" then 9
      when "activeElement" then active_element
      when "URL", "documentURI" then url
      when "baseURI" then base_uri
      when "domain" then domain
      when "referrer" then referrer
      when "links" then links
      when "forms" then forms
      when "scripts" then scripts
      when "images" then images
      when "children" then children
      when "childElementCount" then child_element_count
      when "firstElementChild" then first_element_child
      when "lastElementChild" then last_element_child
      when "nodeName" then "#document"
      else nil
      end
    end

    def __js_set__(key, value)
      case key
      when "title" then write_title(value.to_s)
      when "cookie" then self.cookie = value.to_s
      end
      nil
    end

    def __js_call__(method, args)
      case method
      when "createElement"
        create_element(args[0])
      when "createElementNS"
        create_element_ns(args[0], args[1])
      when "createTextNode"
        create_text_node(args[0])
      when "createComment"
        create_comment(args[0])
      when "createDocumentFragment"
        create_document_fragment
      when "querySelector"
        query_selector(args[0])
      when "querySelectorAll"
        query_selector_all(args[0])
      when "getElementById"
        get_element_by_id(args[0])
      when "getElementsByClassName"
        get_elements_by_class_name(args[0])
      when "getElementsByTagName"
        get_elements_by_tag_name(args[0])
      when "getElementsByName"
        get_elements_by_name(args[0])
      when "createAttribute"
        create_attribute(args[0])
      when "createAttributeNS"
        create_attribute_ns(args[0], args[1])
      when "createTreeWalker"
        create_tree_walker(args[0], args[1] || NodeFilter::SHOW_ALL, args[2])
      when "createNodeIterator"
        create_node_iterator(args[0], args[1] || NodeFilter::SHOW_ALL, args[2])
      when "createEvent"
        create_event(args[0])
      when "importNode"
        import_node(args[0], args[1])
      when "adoptNode"
        adopt_node(args[0])
      when "hasFocus"
        has_focus?
      when "getSelection"
        get_selection
      when "elementFromPoint"
        element_from_point(args[0], args[1])
      when "queryCommandSupported"
        query_command_supported(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "write"
        write(*args)
      when "open"
        open
      when "close"
        close
      else
        nil
      end
    end

    def __event_parent__
      @default_view
    end

    def wrap_node(node)
      return nil unless node

      @node_wrappers[node.object_id] ||= begin
        if node.element?
          # First check for a registered Custom Element (tag with a
          # hyphen, registered via `customElements.define`); else fall
          # back to the built-in HTMLElement subclass map; else
          # generic Element.
          klass = custom_element_class_for(node.name) ||
                  Dommy.element_class_for(node.name)
          klass.new(self, node)
        elsif node.text?
          TextNode.new(self, node)
        elsif node.is_a?(Nokogiri::XML::Comment)
          CommentNode.new(self, node)
        elsif node.is_a?(Nokogiri::XML::DocumentFragment)
          Fragment.new(self, node)
        end
      end
    end

    # Clear the cached wrapper so the next `wrap_node` creates a new
    # one. Used by `customElements.define` to upgrade nodes that were
    # constructed before the registration landed.
    def __reset_wrapper__(nokogiri_node)
      @node_wrappers.delete(nokogiri_node.object_id)
    end

    # ShadowRoot identity registry: map a Nokogiri DocumentFragment
    # (the shadow tree's backing node) to the wrapping ShadowRoot so
    # slot assignment and event composition can walk from any inner
    # node back to its shadow boundary.
    def __register_shadow_fragment__(fragment_node, shadow_root)
      @shadow_roots ||= {}
      @shadow_roots[fragment_node.object_id] = shadow_root
    end

    def __shadow_root_for_fragment__(fragment_node)
      return nil unless @shadow_roots && fragment_node

      @shadow_roots[fragment_node.object_id]
    end

    # Walk from any Nokogiri node up to the nearest enclosing
    # ShadowRoot, or nil if there is none (i.e. the node is in the
    # light DOM only).
    def __shadow_root_containing__(node)
      current = node
      while current && !current.is_a?(Nokogiri::XML::Document)
        sr = __shadow_root_for_fragment__(current)
        return sr if sr

        current = current.respond_to?(:parent) ? current.parent : nil
      end
      nil
    end

    # Lifecycle callback dispatchers. Errors raised inside user
    # callbacks are swallowed so a single buggy custom element can't
    # break the whole mutation pipeline.
    def __notify_connected__(element)
      return unless element&.respond_to?(:connected_callback)

      element.connected_callback
    rescue StandardError
      nil
    end

    def __notify_disconnected__(element)
      return unless element&.respond_to?(:disconnected_callback)

      element.disconnected_callback
    rescue StandardError
      nil
    end

    def __notify_attribute_changed__(element, name, old_value, new_value)
      return unless element&.respond_to?(:attribute_changed_callback)

      klass = element.class
      return unless klass.respond_to?(:observed_attributes)
      return unless klass.observed_attributes.include?(name.to_s.downcase)

      element.attribute_changed_callback(name, old_value, new_value)
    rescue StandardError
      nil
    end

    def custom_element_class_for(tag)
      return nil unless @default_view&.custom_elements

      @default_view.custom_elements.get(tag.downcase)
    end

    def register_observer(observer)
      @observers << observer unless @observers.include?(observer)
      nil
    end

    def unregister_observer(observer)
      @observers.delete(observer)
      nil
    end

    def notify_child_list_mutation(target_node:, added_nodes:, removed_nodes:)
      target = wrap_node(target_node)
      return nil unless target
      return nil if added_nodes.empty? && removed_nodes.empty?

      wrapped_added   = added_nodes.map { |node| wrap_node(node) }.compact
      wrapped_removed = removed_nodes.map { |node| wrap_node(node) }.compact

      # Fire Custom Element lifecycle callbacks (synchronous, before
      # MutationObserver microtask delivery).
      wrapped_added.each { |el| __notify_connected__(el) }
      wrapped_removed.each { |el| __notify_disconnected__(el) }

      record = MutationRecord.new(
        type: "childList",
        target: target,
        added_nodes: wrapped_added,
        removed_nodes: wrapped_removed
      )
      @observers.each do |observer|
        observer.enqueue(record) if observer.matches?(target)
      end
      nil
    end

    # Fire MutationObserver attribute records. Called from Element on
    # setAttribute / removeAttribute / className= etc. `old_value` is
    # captured before the mutation; observers that asked for
    # attributeOldValue receive it, others see nil.
    def notify_attribute_mutation(target_node:, attribute_name:, old_value:)
      target = wrap_node(target_node)
      return nil unless target

      attr = attribute_name.to_s.downcase
      new_value = target_node[attr]

      # Custom Element `attributeChangedCallback` (synchronous,
      # filtered by the element's `observedAttributes`).
      __notify_attribute_changed__(target, attr, old_value, new_value)

      @observers.each do |observer|
        entry = observer.observer_entry(target_node)
        next unless entry && entry[:attributes]

        filter = entry[:attribute_filter]
        next if filter && !filter.include?(attr)

        observer.enqueue(MutationRecord.new(
          type: "attributes",
          target: target,
          attribute_name: attr,
          old_value: entry[:attribute_old_value] ? old_value : nil
        ))
      end
      nil
    end

    # Fire MutationObserver characterData records. Called from
    # TextNode / CommentNode when their data is rewritten.
    def notify_character_data_mutation(target_node:, old_value:)
      target = wrap_node(target_node)
      return nil unless target

      @observers.each do |observer|
        entry = observer.observer_entry(target_node)
        next unless entry && entry[:character_data]

        observer.enqueue(MutationRecord.new(
          type: "characterData",
          target: target,
          old_value: entry[:character_data_old_value] ? old_value : nil
        ))
      end
      nil
    end

    def create_element(name)
      return nil if name.nil? || name.to_s.empty?

      wrap_node(Nokogiri::XML::Node.new(name.to_s, @nokogiri_doc))
    end

    def create_text_node(text)
      wrap_node(Nokogiri::XML::Text.new(text.to_s, @nokogiri_doc))
    end

    def query_selector(selector)
      return nil if selector.nil? || selector.to_s.empty?

      wrap_node(@nokogiri_doc.at_css(selector.to_s))
    end

    def query_selector_all(selector)
      return NodeList.new if selector.nil? || selector.to_s.empty?

      NodeList.new(@nokogiri_doc.css(selector.to_s).map { |node| wrap_node(node) }.compact)
    end

    def get_element_by_id(id)
      return nil if id.nil?

      wrap_node(@nokogiri_doc.at_css("##{id}"))
    end

    # ----- template content helpers (called from Element) -----

    # Parse the given HTML and store it as the template's content
    # fragment. Detaches any prior content + ensures the live template
    # element has no children (so selectors don't see content nodes).
    def attach_template_content(template_element, html)
      # Drop the live element's children — they belong in the fragment.
      template_element.__node__.children.each(&:unlink)
      fragment = @nokogiri_doc.fragment(html.to_s)
      @template_contents[template_element.__node__.object_id] = fragment
      fragment
    end

    # Lazy accessor: if the template element was filled by an outer
    # innerHTML parse (e.g. `body.innerHTML = "<template>...</template>..."`),
    # `migrate_template_descendants` already moved children into a
    # fragment. Returns the wrapped Fragment for `[:content]`.
    def template_content_fragment(template_element)
      fragment = @template_contents[template_element.__node__.object_id]
      # Defensive: if nothing migrated yet (template was set via direct
      # Nokogiri tree manipulation), seed from current children.
      fragment ||= seed_template_content(template_element)
      wrap_node(fragment)
    end

    def template_content_inner_html(template_element)
      fragment = @template_contents[template_element.__node__.object_id]
      return "" unless fragment

      fragment.children.map(&:to_html).join
    end

    # Walk a subtree, finding `<template>` elements that still have
    # children and reparenting their children into a fragment. Called
    # after any innerHTML / fragment-parsing pass so subsequent
    # selectors don't surface template-content nodes.
    def migrate_template_descendants(root)
      targets = []
      targets << root if root.respond_to?(:name) && root.name == "template" && !@template_contents.key?(root.object_id)
      root.traverse do |node|
        next unless node.respond_to?(:name) && node.name == "template"
        next if @template_contents.key?(node.object_id)

        targets << node
      end
      targets.uniq!
      targets.each { |t| migrate_one_template(t) }
    end

    private

    # Build a Nokogiri copy of the given node inside our @nokogiri_doc.
    # `deep: true` recurses into children. Used by importNode and
    # adoptNode for cross-document transfer.
    def clone_into_doc(source, deep)
      copy = if source.element?
               new_el = Nokogiri::XML::Node.new(source.name, @nokogiri_doc)
               source.attribute_nodes.each { |a| new_el[a.name] = a.value }
               new_el
             elsif source.text?
               Nokogiri::XML::Text.new(source.content, @nokogiri_doc)
             elsif source.is_a?(Nokogiri::XML::Comment)
               Nokogiri::XML::Comment.new(@nokogiri_doc, source.content)
             else
               # Fallback: serialize + reparse via fragment for unusual types.
               fragment = Parser.fragment(source.to_html, owner_doc: @nokogiri_doc)
               fragment.children.first || Nokogiri::XML::Text.new("", @nokogiri_doc)
             end

      if deep && source.respond_to?(:children)
        source.children.each do |child|
          copy.add_child(clone_into_doc(child, true))
        end
      end
      copy
    end

    def read_title
      head = @nokogiri_doc.at_css("head")
      title = head&.at_css("title")
      title ? title.text : ""
    end

    def write_title(value)
      head = @nokogiri_doc.at_css("head")
      return unless head

      title = head.at_css("title")
      unless title
        title = Nokogiri::XML::Node.new("title", @nokogiri_doc)
        head.add_child(title)
      end
      title.children.each(&:unlink)
      title.add_child(Nokogiri::XML::Text.new(value, @nokogiri_doc))
    end

    def seed_template_content(template_element)
      node = template_element.__node__
      migrate_one_template(node)
      @template_contents[node.object_id]
    end

    def migrate_one_template(template_node)
      fragment = @nokogiri_doc.fragment("")
      children = template_node.children.to_a
      children.each do |child|
        child.unlink
        fragment.add_child(child)
      end
      @template_contents[template_node.object_id] = fragment
    end
  end
end
