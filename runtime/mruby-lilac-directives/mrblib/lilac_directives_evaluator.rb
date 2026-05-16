module Lilac
  module Directives
    # Resolves a parsed `Value` (Ivar or ItPath) against a host
    # component and an optional iteration item.
    #
    # Two main entry points mirror the CLI codegen's polymorphic
    # methods on DirectiveValue:
    #
    #   - `bind_source(value, item)` — returns an object suitable as
    #     a `bind ref, prop: source` argument. For Ivar, that's the
    #     Signal directly (host.bind calls `.value` inside an effect).
    #     For ItPath, that's a `host.computed { ... }` so re-rendering
    #     is reactive when the item changes.
    #
    #   - `read(value, item)` — returns the current scalar value, for
    #     use inside an already-reactive context (effect / computed
    #     block created by the dispatcher).
    class Evaluator
      def initialize(host)
        @host = host
      end

      def bind_source(value, item)
        case value
        when Value::Ivar
          @host.instance_variable_get(value.ivar_sym)
        when Value::ItPath
          field = value.field
          @host.computed { field ? read_field(item, field) : item }
        end
      end

      def read(value, item)
        case value
        when Value::Ivar
          sig = @host.instance_variable_get(value.ivar_sym)
          sig.value
        when Value::ItPath
          field = value.field
          field ? read_field(item, field) : item
        end
      end

      private

      # Iteration items can be plain Hashes (`{ id: 1, title: "x" }`)
      # or Data / Struct-like objects (`Todo.new(id: 1, title: "x")`).
      # Hashes lookup by symbol key; everything else uses `public_send`,
      # which lets `?` predicates on the field name (`it.done?`)
      # dispatch as ordinary method calls.
      def read_field(item, field)
        return nil if item.nil?
        if item.is_a?(Hash)
          item[field.to_sym]
        else
          item.public_send(field.to_sym)
        end
      end
    end
  end
end
