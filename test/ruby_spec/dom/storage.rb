# frozen_string_literal: true

class MrubyWasm
  module Dom
    # Hash-backed `Storage` polyfill for `localStorage` /
    # `sessionStorage`. Mirrors the Web Storage API subset Lilac uses:
    # `getItem(key)`, `setItem(key, value)`, `removeItem(key)`,
    # `clear()`, `key(index)`, `length`. Values are coerced to String
    # to match browser semantics (browser stores everything as String).
    #
    # No persistence across `MrubyWasm.new` instances — each fresh VM
    # gets an empty Storage. Tests that depend on cross-instance
    # behaviour (none currently) would need explicit hydration.
    class Storage
      def initialize
        @store = {}
      end

      def __js_get__(key)
        case key
        when "length" then @store.size
        else
          # Allows `localStorage[:foo]` to return the value — Web Storage
          # supports this via the Proxy-like trap.
          @store[key]
        end
      end

      def __js_set__(key, value)
        @store[key] = value.to_s
      end

      def __js_call__(method, args)
        case method
        when "getItem"
          @store[args[0].to_s]
        when "setItem"
          @store[args[0].to_s] = args[1].to_s
          nil
        when "removeItem"
          @store.delete(args[0].to_s)
          nil
        when "clear"
          @store.clear
          nil
        when "key"
          @store.keys[args[0].to_i]
        end
      end
    end
  end
end
