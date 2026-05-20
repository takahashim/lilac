# frozen_string_literal: true

require_relative "parser"

class MrubyWasm
  module Dom
    # `document` — the entry point for DOM construction and querying.
    # Session 1 ships only the scaffold needed for `JS.global[:document]`
    # and `document[:body]` to return valid handles. Element methods
    # (innerHTML, querySelector, etc.) arrive in session 2-3.
    class Document
      attr_reader :body

      def initialize(host)
        @host = host
        # Each Document owns a fresh Nokogiri HTML document so `body`
        # is a real Element (not a free-floating node). The document
        # has minimal `<html><head></head><body></body></html>`
        # structure — enough for `body` to be queryable.
        @nokogiri_doc = Nokogiri::HTML5("<!doctype html><html><head></head><body></body></html>")
        @body = Element.new(self, @nokogiri_doc.at_css("body"))
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
    end

    # Element scaffold. Session 1 only exposes the constructor; all
    # property access / methods return nil for now. Session 2 fills
    # in attributes / innerHTML / textContent / children / parent.
    class Element
      attr_reader :__node__

      def initialize(document, nokogiri_node)
        @document = document
        @__node__ = nokogiri_node
      end

      def __js_get__(_key)
        nil
      end

      def __js_set__(_key, _value)
        nil
      end

      def __js_call__(_method, _args)
        nil
      end
    end
  end
end
