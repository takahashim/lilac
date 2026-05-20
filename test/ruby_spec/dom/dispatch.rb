# frozen_string_literal: true

class MrubyWasm
  module Dom
    # Helper for routing bridge calls (js_get / js_set / js_call /
    # js_new) to handle values that implement the duck-typed
    # `__js_*__` protocol.
    #
    # The actual dispatch decision lives in `mruby_wasm.rb`'s
    # `js_get` / `js_set` / `js_call` / `js_new` stubs: when the
    # handle's value `respond_to?(:__js_get__)` etc., this module's
    # methods get the value and the args. Otherwise the existing Hash /
    # Array / sentinel paths handle it.
    #
    # Keeping the dispatch indirection here (rather than littering
    # branches in mruby_wasm.rb) keeps the bridge stubs concise as the
    # DOM polyfill grows session by session.
    module Dispatch
      module_function

      # Returns true if the value participates in the DOM protocol.
      def dom_value?(value)
        value.respond_to?(:__js_get__) ||
          value.respond_to?(:__js_set__) ||
          value.respond_to?(:__js_call__)
      end

      def get(value, key)
        return nil unless value.respond_to?(:__js_get__)

        value.__js_get__(key)
      end

      def set(value, key, new_value)
        return nil unless value.respond_to?(:__js_set__)

        value.__js_set__(key, new_value)
      end

      def call(value, method, args)
        return nil unless value.respond_to?(:__js_call__)

        value.__js_call__(method, args)
      end
    end
  end
end
