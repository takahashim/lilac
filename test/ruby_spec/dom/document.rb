# frozen_string_literal: true

class MrubyWasm
  module Dom
    # `document` — the entry point for DOM construction and querying.
    # Session 2 adds wrapper caching so repeated traversals
    # (`body.children[0].parentElement`) preserve DOM identity.
    class Document
      attr_reader :body

      def initialize(host)
        @host = host
        @node_wrappers = {}
        # Each Document owns a fresh Nokogiri HTML document so `body`
        # is a real Element (not a free-floating node). The document
        # has minimal `<html><head></head><body></body></html>`
        # structure — enough for `body` to be queryable.
        @nokogiri_doc = Nokogiri::HTML5("<!doctype html><html><head></head><body></body></html>")
        @body = wrap_node(@nokogiri_doc.at_css("body"))
      end

      def __js_get__(key)
        case key
        when "body" then @body
        else nil
        end
      end

      def __js_set__(_key, _value)
        nil
      end

      def __js_call__(_method, _args)
        case _method
        when "createElement"
          create_element(_args[0])
        when "createTextNode"
          create_text_node(_args[0])
        when "querySelector"
          query_selector(_args[0])
        when "querySelectorAll"
          query_selector_all(_args[0])
        else
          nil
        end
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
    end
  end
end
