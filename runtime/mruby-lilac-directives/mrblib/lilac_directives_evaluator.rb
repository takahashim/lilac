module Lilac
  module Directives
    # Resolves a parsed `Value` (Ivar / BareIdent) against a host
    # component and an optional iteration item.
    #
    # Public surface:
    #
    #   - `bind_source(value, item)` — returns an object suitable as a
    #     `bind ref, prop: source` argument. For Ivar, that's the Signal
    #     itself (host.bind calls `.value` inside an effect). For
    #     BareIdent, that's a `host.computed { ... }` so the binding
    #     stays reactive across item changes.
    #
    #   - `read_raw(value, item)` — canonical resolver. Returns whatever
    #     the value points at (Signal object for Ivar, raw stored value
    #     for BareIdent — which itself may be a Signal if the item stores
    #     Signals, or a plain scalar otherwise).
    #
    #   - `read(value, item)` — resolves to the current scalar. An
    #     Ivar's Signal, and a BareIdent pointing at a per-row reactive
    #     value, are both read via `.value`; plain values pass through.
    class Evaluator
      def initialize(host)
        @host = host
      end

      def bind_source(value, item)
        return lookup_ivar(value) if value.is_a?(Value::Ivar)
        # BareIdent → reactive computed so the binding re-evaluates when the
        # item reference changes. `read` unwraps a per-row reactive field so
        # the computed subscribes to it.
        @host.computed { read(value, item) }
      end

      def read_raw(value, item)
        case value
        when Value::Ivar
          lookup_ivar(value)
        when Value::BareIdent
          ItemField.read(item, value.field)
        end
      end

      def read(value, item)
        resolved = read_raw(value, item)
        # Ivar values are Signals by convention — read the current scalar.
        return resolved.value if value.is_a?(Value::Ivar)

        # A BareIdent may point at a per-row reactive value; read its
        # `.value` so it resolves to the scalar and, inside a reactive
        # context, subscribes. Plain values pass through.
        resolved.is_a?(Reactive::Subscribable) ? resolved.value : resolved
      end

      # Resolve a Value::Ivar to the host's underlying object (typically
      # a Signal / Computed). This is the single place in the directive
      # subsystem that reaches into host instance-variable state via
      # reflection — keep the metaprog surface contained here so other
      # call sites only see `lookup_ivar(value)`.
      def lookup_ivar(value)
        @host.instance_variable_get(value.ivar_sym)
      end
    end
  end
end
