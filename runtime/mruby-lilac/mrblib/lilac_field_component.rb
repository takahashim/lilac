# lilac_field_component.rb — Base class for stateful input components.
#
# Subclass to expose a `value` signal as a public API, suitable for use as
# `f.field :name, source: refs.X.component` in a parent form (form-spec
# §3.1, §5). The base class owns the convention so child input components
# only declare initial value and (optionally) override `reset`.
#
# Lives in mruby-lilac core (not the form gem) because `value`/`reset` are
# generic "stateful input" contract pieces — form integration is one
# consumer but not the only possible one.

module Lilac
  class FieldComponent < Component
    attr_reader :value

    # Subclass overrides for non-empty defaults (e.g. checkbox → false,
    # date → today). Called by base `setup` and `reset` so both stay in sync.
    def initial_value
      ""
    end

    def setup
      @value = signal(initial_value)
    end

    # Default reset: write initial_value back into @value. No-op when the
    # subclass redefined @value as a Computed (read-only composite value);
    # those subclasses are expected to override reset themselves to reset
    # the underlying signals (see form-spec §5 DatePicker example).
    def reset
      @value.value = initial_value if @value.respond_to?(:value=)
      nil
    end
  end
end
