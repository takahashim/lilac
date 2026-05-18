module Lilac
  module Directives
    # Resolves a parsed `Value` (Ivar / BareIdent / ItPath) against a host
    # component and an optional iteration item.
    #
    # Two main entry points mirror the CLI codegen's polymorphic
    # methods on DirectiveValue:
    #
    #   - `bind_source(value, item)` — returns an object suitable as
    #     a `bind ref, prop: source` argument. For Ivar, that's the
    #     Signal directly (host.bind calls `.value` inside an effect).
    #     For BareIdent / ItPath, that's a `host.computed { ... }` so
    #     re-rendering is reactive when the item changes.
    #
    #   - `read(value, item)` — returns the current scalar value, for
    #     use inside an already-reactive context (effect / computed
    #     block created by the dispatcher).
    #
    #   - `read_raw(value, item)` — like `read` but does NOT unwrap the
    #     resolved value via `.value`. Used by `data-bind` which needs
    #     the Signal object itself to wire `bind_input`.
    class Evaluator
      def initialize(host)
        @host = host
      end

      def bind_source(value, item)
        case value
        when Value::Ivar
          lookup_ivar(value)
        when Value::ItPath
          field = value.field
          @host.computed { field ? read_field(item, field) : item }
        when Value::BareIdent
          field = value.field
          @host.computed { read_field(item, field) }
        end
      end

      def read(value, item)
        case value
        when Value::Ivar
          lookup_ivar(value).value
        when Value::ItPath
          field = value.field
          field ? read_field(item, field) : item
        when Value::BareIdent
          read_field(item, value.field)
        end
      end

      # Same as `read` but skips the final `.value` unwrap on Ivar.
      # data-bind uses this to grab the Signal object itself (needed
      # by `bind_input` for two-way wiring). For BareIdent / ItPath
      # the field lookup already returns whatever is stored on the
      # item (typically a Signal when row-level bind is intended).
      def read_raw(value, item)
        case value
        when Value::Ivar
          lookup_ivar(value)
        when Value::ItPath
          field = value.field
          field ? read_field(item, field) : item
        when Value::BareIdent
          read_field(item, value.field)
        end
      end

      # Resolve a Value::Ivar to the host's underlying object (typically a
      # Signal / Computed). This is the single place in the directive
      # subsystem that reaches into host instance-variable state via
      # reflection — keep the metaprog surface contained here so other
      # call sites only see `lookup_ivar(value)`.
      def lookup_ivar(value)
        @host.instance_variable_get(value.ivar_sym)
      end

      private

      # Iteration items can be plain Hashes (`{ id: 1, title: "x" }`
      # or JSON-loaded `{ "id" => 1, "title" => "x" }`) or Data /
      # Struct-like objects. Hashes try Symbol key first, then String;
      # everything else uses `public_send`, which lets `?` predicates
      # on the field name (`it.done?`) dispatch as ordinary calls.
      def read_field(item, field)
        return nil if item.nil?
        if item.is_a?(Hash)
          sym = field.to_sym
          if item.key?(sym)
            item[sym]
          else
            item[field]
          end
        else
          item.public_send(field.to_sym)
        end
      end
    end
  end
end
