module Lilac
  module Directives
    # Single-source field lookup for an iteration item. Used by
    # `Evaluator` (resolving `it.field` / bare-ident directive values)
    # and `PropAutoFill` (mapping item fields onto child component
    # props). Centralizes the precedence so any future tweak — Data
    # objects, predicate methods, frozen-key semantics — lives in one
    # place.
    #
    # Lookup order:
    #   1. `Hash` → Symbol key first, String key fallback
    #   2. otherwise → `public_send(name.to_sym)` if responded to
    #
    # Returns `nil` if `item` is nil, or if neither path yields a value.
    # Callers distinguish "missing" from "stored nil" via `has?` when
    # they need to (auto-fill currently treats nil-or-missing the same:
    # skip the write, let the child's prop default / required-check
    # take over).
    module ItemField
      class << self
        def read(item, name)
          return nil if item.nil?
          if item.is_a?(Hash)
            sym = name.to_sym
            return item[sym] if item.key?(sym)
            str = name.to_s
            return item[str] if item.key?(str)
            nil
          elsif item.respond_to?(name.to_sym)
            item.public_send(name.to_sym)
          end
        end

        # Explicit presence check for callers that need to distinguish
        # "field is nil" from "field is absent". Returns true if the
        # item has a routable accessor for `name` (Hash key OR public
        # method), regardless of stored value.
        def has?(item, name)
          return false if item.nil?
          if item.is_a?(Hash)
            item.key?(name.to_sym) || item.key?(name.to_s)
          else
            item.respond_to?(name.to_sym)
          end
        end
      end
    end
  end
end
