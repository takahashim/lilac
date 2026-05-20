# frozen_string_literal: true

require_relative "parser"

class MrubyWasm
  module Dom
    # Session 2 covers the read-mostly Element/Node surface needed by
    # Lilac's tree walkers: attributes, text/html reads, parent/child
    # traversal, and `closest`.
    class Element
      attr_reader :__node__

      def initialize(document, nokogiri_node)
        @document = document
        @__node__ = nokogiri_node
      end

      def __js_get__(key)
        case key
        when "children"
          element_children
        when "parentElement", "parent"
          wrap_parent(@__node__.parent)
        when "textContent"
          @__node__.text
        when "innerHTML"
          @__node__.inner_html
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
        when "getAttribute"
          get_attribute(args[0])
        when "setAttribute"
          set_attribute(args[0], args[1])
        when "hasAttribute"
          has_attribute?(args[0])
        when "closest"
          closest(args[0])
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

      def get_attribute(name)
        return nil if name.nil?

        @__node__[name.to_s]
      end

      def set_attribute(name, value)
        return nil if name.nil?

        @__node__[name.to_s] = value.to_s
        nil
      end

      def has_attribute?(name)
        return false if name.nil?

        @__node__.key?(name.to_s)
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
