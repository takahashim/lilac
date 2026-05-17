# Lilac Form Builder — signal-based form state + validation.
#
# Headless, data-only form state. Components provide the HTML; this gem
# provides per-field reactive state (`value`, `dirty?`, `touched?`,
# `error`, `valid?`) on top of Lilac's existing bindings.
#
# The form block receives the Form instance explicitly (no `instance_eval`)
# so component instance variables and methods remain accessible inside
# validator blocks.
#
# This lives in the optional `mruby-lilac-form` gem rather than core.
# See `mrbgem/mruby-lilac-form/README.md` for usage.
module Lilac
  class Form
    # Maps field type → which DOM property `bind_input` should bind.
    TYPE_TO_PROPERTY = {
      text:     :value,
      checkbox: :checked,
      select:   :value,
    }.freeze

    class Field
      attr_reader :name
      attr_reader :value_signal, :dirty_signal, :touched_signal, :error_signal
      attr_reader :source_component

      # ref: / initial: are now both optional. Resolution rules:
      #   - source: given        → use external Signal / FieldComponent.value
      #                            as the value_signal (no bind_input)
      #   - ref:    given        → component.bind_input(ref, signal) immediately
      #   - neither              → deferred binding; scanner calls bind_to(ref) later
      #
      # source: polymorphic dispatch — FieldComponent gets reset propagation;
      # raw Signal/Computed gets used as-is (no reset propagation).
      def initialize(name:, component:,
                     ref: nil, initial: nil, source: nil,
                     type: :text, validator: nil, form: nil)
        raise ArgumentError, "source: and initial: cannot both be given" if source && !initial.nil?

        @name = name
        @component = component
        @validator = validator
        @form = form
        @type = type
        @bound = false

        setup_value_signal(source: source, initial: initial, ref: ref)
        setup_dirty_tracking
        setup_meta_signals
        setup_error_signals
      end

      # Whether this field's value signal is externally owned (source: was
      # given). Form#reset uses this to decide between full reset and
      # meta-only reset.
      def external_value?
        @external_value
      end

      # Deferred binding from scanner: wires bind_input + blur listener to
      # the discovered <input>. Idempotent-with-raise: a second call signals
      # a logic bug (double-bind would leak listeners).
      def bind_to(ref)
        raise Lilac::Error, "field :#{@name} already bound" if @bound
        if @external_value
          # Source-backed fields don't bind their own input. blur tracking
          # still useful for touched semantics if the source component
          # exposes an <input>, but that's source-side responsibility.
          @bound = true
          return
        end
        property = TYPE_TO_PROPERTY[@type] || :value
        @component.bind_input(ref, @value_signal, property: property)
        ref.on(:blur) { @touched_signal.value = true }
        @bound = true
        nil
      end

      def value
        @value_signal.value
      end

      def value=(v)
        @value_signal.value = v
        nil
      end

      def initial_value
        @initial
      end

      def valid?
        @error_signal.value.nil?
      end

      def invalid?
        !valid?
      end

      def dirty?
        @dirty_signal.value
      end

      def touched?
        @touched_signal.value
      end

      # Show errors after the user has touched the field OR after a
      # submit attempt. Both conditions are reactive when called inside
      # a computed or effect.
      def show_error?
        invalid? && (touched? || (@form ? @form.submit_attempted? : false))
      end

      def error
        @error_signal.value
      end

      def server_error
        @server_error_signal.value
      end

      def touch
        @touched_signal.value = true unless @touched_signal.value
        nil
      end

      def set_server_error(msg)
        @server_error_signal.value = msg
        nil
      end

      def clear_server_error
        @server_error_signal.value = nil
        nil
      end

      # Full reset for owned-signal fields. Source-backed fields use
      # reset_meta_only and let Form#reset delegate value reset to the
      # source component.
      def reset
        @value_signal.value = @initial if @value_signal.respond_to?(:value=) && !@external_value
        reset_meta_only
      end

      # Reset dirty/touched/server_error without touching @value_signal.
      # Form#reset uses this for source-backed fields where the source
      # component owns value resetting.
      def reset_meta_only
        @dirty_signal.value = false
        @touched_signal.value = false
        @server_error_signal.value = nil
        nil
      end

      private

      # Choose value_signal source: external (source: kwarg) vs internal
      # signal owned by this field. Sets @value_signal / @source_component /
      # @external_value / @initial as a coherent group.
      def setup_value_signal(source:, initial:, ref:)
        if source
          setup_external_value_signal(source)
        else
          setup_internal_value_signal(initial, ref)
        end
      end

      def setup_external_value_signal(source)
        if source.is_a?(Lilac::FieldComponent) ||
           (source.respond_to?(:value) && source.respond_to?(:reset))
          @value_signal = source.value
          @source_component = source
        else
          # Raw Signal / Computed — no reset propagation possible.
          @value_signal = source
          @source_component = nil
          Lilac.logger.warn(
            "field :#{@name} source is a raw signal; form.reset will not propagate"
          ) if Lilac.dev_mode?
        end
        @initial = nil   # source-backed fields are not reset by Form#reset directly
        @external_value = true
      end

      def setup_internal_value_signal(initial, ref)
        @initial = initial.nil? ? default_initial_for(@type) : initial
        @value_signal = @component.signal(@initial)
        @source_component = nil
        @external_value = false
        bind_to(ref) if ref
      end

      # Latches `@dirty_signal` to true once value diverges from the baseline
      # captured at init time. For source-backed fields the baseline is the
      # source's current value at field declaration time.
      def setup_dirty_tracking
        @dirty_baseline = @value_signal.value
        @dirty_signal = @component.signal(false)
        @component.effect(label: "form:#{@name}:dirty") do
          v = @value_signal.value
          @dirty_signal.value = true if !@dirty_signal.value && v != @dirty_baseline
        end
      end

      # `@touched_signal` flips on blur (wired in bind_to) and on submit.
      def setup_meta_signals
        @touched_signal = @component.signal(false)
      end

      # Error precedence: server_error → field validator → form-level
      # validator. All three layers participate so a single field can have
      # an SSR error AND a re-validated client error AND a cross-field
      # form-level error without state collision.
      def setup_error_signals
        @server_error_signal = @component.signal(nil)
        @validator_error_computed = @component.computed do
          msg = @validator ? @validator.call(self, @form) : nil
          (msg.is_a?(String) && !msg.empty?) ? msg : nil
        end
        @error_signal = @component.computed do
          @server_error_signal.value ||
            @validator_error_computed.value ||
            (@form && @form.form_error_for(@name).value)
        end
      end

      def default_initial_for(type)
        case type
        when :checkbox then false
        else                ""
        end
      end
    end

    def initialize(component)
      @component                = component
      @fields                = {}
      @buttons               = {}   # name(Symbol) → { handler:, validate: }
      @base_error_signal     = component.signal(nil)
      @submit_attempted_signal  = component.signal(false)
      @form_validator_signal        = component.signal(nil)
      @form_validator_computed = nil
      @form_error_computeds      = {}
    end

    # Primary field accessor.
    def [](name)
      @fields.fetch(name.to_sym)
    end

    # Predicates kept as public API so callers (notably the directive
    # scanner) don't have to reach into `@fields` / `@buttons` ivars.
    def has_field?(name)
      @fields.key?(name.to_sym)
    end

    def has_button?(name)
      @buttons.key?(name.to_sym)
    end

    # Declare a field. The optional block is the field-level validator.
    # It receives (field) or (field, form); Proc ignores extra args.
    #
    # All of ref: / initial: / source: are optional:
    #   - source: takes a FieldComponent (or any Signal) as the value backing
    #   - ref:    immediately wires bind_input (legacy direct API)
    #   - neither → deferred binding via scanner-driven Field#bind_to(ref)
    #
    # source: and initial: are mutually exclusive (raises ArgumentError).
    # Same-name re-registration raises Lilac::Error (typo detection).
    def field(name, ref: nil, initial: nil, source: nil, type: :text, &validator)
      sym = name.to_sym
      if @fields.key?(sym)
        raise Lilac::Error, "field :#{sym} is already declared on this form"
      end
      @fields[sym] = Field.new(
        name: sym, ref: ref, initial: initial, source: source,
        validator: validator, component: @component, type: type, form: self)
    end

    # Named action button declaration. Scanner wires `<button data-button="X">`
    # click → `invoke_button(:X)`. The special name `:submit` is wired to the
    # `<form>` element's submit event (so Enter and `<button type="submit">`
    # both fire it). validate: false skips touch-all + validity check.
    #
    # Same-name re-registration raises (parallels Form#field) — typos like
    # `f.button :submitt` followed by the intended `:submit` would otherwise
    # silently shadow the earlier handler.
    def button(name, validate: true, &handler)
      raise ArgumentError, "block required" unless handler
      sym = name.to_sym
      if @buttons.key?(sym)
        raise Lilac::Error, "button :#{sym} is already declared on this form"
      end
      @buttons[sym] = { handler: handler, validate: validate }
      nil
    end

    # Fire a declared button by name. Used by scanner click/submit handlers
    # and by user code (e.g. test harnesses, programmatic submit). The
    # optional event arg is ignored — handlers see only the values snapshot.
    def invoke_button(name, _event = nil)
      sym = name.to_sym
      spec = @buttons[sym]
      unless spec
        raise Lilac::Error,
              "form has no button :#{sym} (declare via `f.button :#{sym} do |values| ... end`)"
      end
      if spec[:validate]
        submit { |snapshot| spec[:handler].call(snapshot) }
      else
        # validate: false — snapshot current values and invoke handler.
        # submit_attempted is NOT set; touch-all and error display are
        # skipped so non-validating actions (Save Draft, Delete) don't
        # disturb the form UI.
        spec[:handler].call(values)
      end
    end

    def fields
      @fields
    end

    # Plain hash of current field values (snapshot, not reactive).
    def values
      @fields.each_with_object({}) { |(n, f), h| h[n] = f.value }
    end

    # Plain hash of fields that currently have errors.
    def errors
      @fields.each_with_object({}) { |(n, f), h| e = f.error; h[n] = e if e }
    end

    # Register a form-level validator. Block receives the form object and
    # returns Hash<Symbol, String> or nil. A second call replaces the first.
    def validate(&block)
      raise ArgumentError, "block required" unless block
      @form_validator_signal.value = block
      nil
    end

    # Reactive computed of the form-level validator result Hash.
    # Reads form[:name].value inside the block, which auto-tracks each
    # field's signal when evaluated inside this computed.
    def form_validator_computed
      @form_validator_computed ||= @component.computed do
        block = @form_validator_signal.value
        next {} unless block
        result = block.call(self)
        result.is_a?(Hash) ? result : {}
      end
    end

    # Cached per-field computed of the form-level error for one field.
    def form_error_for(name)
      sym = name.to_sym
      @form_error_computeds[sym] ||= @component.computed do
        msg = form_validator_computed.value[sym]
        (msg.is_a?(String) && !msg.empty?) ? msg : nil
      end
    end

    # ---- Aggregate validity ----

    def valid?
      @fields.values.all? { |f| f.error.nil? }
    end

    def invalid?
      !valid?
    end

    def submit_attempted?
      @submit_attempted_signal.value
    end

    # Returns the current form-level error string or nil (plain value).
    def base_error
      @base_error_signal.value
    end

    # Reactive source for use with `bind`.
    def base_error_signal
      @base_error_signal
    end

    def set_base_error(msg)
      @base_error_signal.value = msg
      nil
    end

    def clear_base_error
      @base_error_signal.value = nil
      nil
    end

    # Mark submit attempted, touch all fields, call block only if valid.
    def submit(&block)
      @submit_attempted_signal.value = true
      clear_base_error
      @fields.each_value(&:touch)
      return unless valid?
      block.call(values) if block
      nil
    end

    # Reset all fields and form-level state. For source-backed fields
    # (`source: refs.X.component`), the value signal is owned by the source
    # component, so we delegate value reset to that component's `reset`
    # method (no-op if the source is a raw Signal without `reset`). The
    # field's own dirty/touched/server_error are always reset.
    def reset
      @fields.each_value do |field|
        if field.external_value?
          src = field.source_component
          src.reset if src && src.respond_to?(:reset)
          field.reset_meta_only
        else
          field.reset
        end
      end
      @submit_attempted_signal.value = false
      clear_base_error
      nil
    end

    # Inject server-side field errors. Unknown keys are silently ignored.
    def set_server_errors(errors)
      errors.each do |name, msg|
        f = @fields[name.to_sym]
        f&.set_server_error(msg)
      end
      nil
    end
  end

  # Common validator helpers. Compose with `||` so the first non-nil wins.
  # All except `required` use skip-on-blank semantics: blank values return
  # nil so optional fields can have length checks without becoming required.
  #
  # `extend self` makes the same methods available both as module-level
  # singleton methods (`Lilac::Form::Validators.required(v)`) and as
  # instance methods when mixed in via FormBuilder.
  module Form::Validators
    extend self

    def required(v, message: "required")
      blank?(v) ? message : nil
    end

    def min_length(v, n, message: nil)
      return nil if blank?(v)
      return nil if v.length >= n
      message || "must be at least #{n} characters"
    end

    def max_length(v, n, message: nil)
      return nil if blank?(v)
      return nil if v.length <= n
      message || "must be at most #{n} characters"
    end

    def length_in(v, range, message: nil)
      return nil if blank?(v)
      return nil if range.cover?(v.length)
      message || "length must be in #{range}"
    end

    def inclusion(v, list, message: nil)
      return nil if blank?(v)
      return nil if list.include?(v)
      message || "must be one of: #{list.join(", ")}"
    end

    # Checkbox-specific: false is the "needs attention" value.
    def acceptance(v, message: "must be accepted")
      v ? nil : message
    end

    private

    def blank?(v)
      v.nil? || (v.is_a?(String) && v.empty?)
    end
  end

  # Adds `form` and bare validator helpers to components when this gem is loaded.
  #
  # `form` is dual-purpose: block-with registers, block-less looks up (and
  # auto-creates when missing — applies uniformly to default and named forms).
  # Same-name re-registration raises so typos / accidental double-declare
  # surface immediately.
  module FormBuilder
    include Lilac::Form::Validators

    def form(name = :default, &block)
      @form_registry ||= {}
      sym = name.to_sym
      if block
        if @form_registry.key?(sym)
          raise Lilac::Error,
                "form #{sym.inspect} is already declared in this component " \
                "(use `form.reset` to clear values, or a different name for a new form)"
        end
        f = Lilac::Form.new(self)
        @form_registry[sym] = f
        block.call(f)
        f
      else
        @form_registry[sym] ||= Lilac::Form.new(self)
      end
    end
  end
end

Lilac::Component.include(Lilac::FormBuilder)
