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
        # createElement / createTextNode arrive in session 3.
        nil
      end

      def wrap_node(node)
        return nil unless node&.element?

        @node_wrappers[node.object_id] ||= Element.new(self, node)
      end
    end
  end
end
