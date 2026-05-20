# frozen_string_literal: true

class MrubyWasm
  module Dom
    # `document` — the entry point for DOM construction and querying.
    # Wrapper caching keeps DOM identity stable across repeated
    # traversals (`body.children[0].parentElement`).
    class Document
      include EventTarget

      attr_reader :body, :nokogiri_doc
      attr_accessor :default_view

      def initialize(host)
        @host = host
        @node_wrappers = {}
        @observers = []
        # `<template>` content lives in a separate DocumentFragment in
        # real DOM — invisible to selectors. We mirror that by reparenting
        # any template's children into a fragment stored here, keyed by
        # the template element's Nokogiri object_id. The template
        # element itself becomes empty in the live tree.
        @template_contents = {}
        @nokogiri_doc = Nokogiri::HTML5("<!doctype html><html><head></head><body></body></html>")
        @body = wrap_node(@nokogiri_doc.at_css("body"))
      end

      def __js_get__(key)
        case key
        when "body" then @body
        when "defaultView" then @default_view
        when "documentElement" then wrap_node(@nokogiri_doc.at_css("html"))
        when "title" then read_title
        else nil
        end
      end

      def __js_set__(key, value)
        case key
        when "title" then write_title(value.to_s)
        end
        nil
      end

      def __js_call__(method, args)
        case method
        when "createElement"
          create_element(args[0])
        when "createTextNode"
          create_text_node(args[0])
        when "querySelector"
          query_selector(args[0])
        when "querySelectorAll"
          query_selector_all(args[0])
        when "getElementById"
          get_element_by_id(args[0])
        when "addEventListener"
          add_event_listener(args[0], args[1], args[2])
        when "removeEventListener"
          remove_event_listener(args[0], args[1])
        when "dispatchEvent"
          dispatch_event(args[0])
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
            Element.new(self, node)
          elsif node.text?
            TextNode.new(self, node)
          elsif node.is_a?(Nokogiri::XML::DocumentFragment)
            Fragment.new(self, node)
          end
        end
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

        record = MutationRecord.new(
          target: target,
          added_nodes: added_nodes.map { |node| wrap_node(node) }.compact,
          removed_nodes: removed_nodes.map { |node| wrap_node(node) }.compact
        )
        @observers.each do |observer|
          observer.enqueue(record) if observer.matches?(target)
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
        return [] if selector.nil? || selector.to_s.empty?

        @nokogiri_doc.css(selector.to_s).map { |node| wrap_node(node) }.compact
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
end
