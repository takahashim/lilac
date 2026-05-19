module Lilac
  # Single-source field lookup for an iteration item. Used by:
  #
  # 1. `Lilac::Directives::Evaluator` (runtime scanner) — resolving
  #    `it.field` / bare-ident directive values during DOM walk.
  # 2. `Lilac::Directives::PropAutoFill` — mapping item fields onto
  #    child component props inside `data-each`.
  # 3. CLI codegen emitted code — `bind ..., text: computed { Lilac::
  #    ItemField.read(it, :label) }` etc. for `data-text` / `data-bind`
  #    / `data-attr-*` against iteration item fields. Codegen emits
  #    this instead of the bare `it.<field>` method-call form so that
  #    Hash items (the common shape — JSON-decoded data) work without
  #    NoMethodError.
  #
  # Lives in `mruby-lilac` core (not `mruby-lilac-directives`) because
  # the CLI codegen path may need it in builds that exclude the runtime
  # scanner (`lilac-compiled` variant).
  #
  # Lookup order:
  #   1. `Hash` → Symbol key first, String key fallback
  #   2. otherwise → `public_send(name.to_sym)` if responded to
  #
  # Returns `nil` if `item` is nil, or if neither path yields a value.
  # Callers distinguish "missing" from "stored nil" via `has?` when
  # they need to (PropAutoFill currently treats nil-or-missing the
  # same: skip the write, let the child's prop default / required-check
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
