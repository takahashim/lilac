# lilac_props.rb — Component props mechanism.
#
# Read declarative configuration from `data-prop-*` HTML attributes and
# expose them as `props.X` and `@X` Signal ivars. See docs/lilac-props-spec.md.
#
# `prop :title, String` declares both:
#   - `props.title` read-through accessor (returns current scalar)
#   - `@title` Signal ivar, auto-initialized at mount with the coerced value
#
# Types: String / Integer / Float / Lilac::Boolean.
# Boolean rule: "true"/"false" + presence shortcut, others raise.
# Defaults: optional via `default:`; absent default + missing attr → raise.
# Attribute naming: `data-prop-max-length` → `@max_length` (kebab→snake).

module Lilac
  # Sentinel module used as the `Boolean` type marker in `prop` declarations.
  # Ruby lacks a built-in Boolean class, so users write
  # `prop :disabled, Lilac::Boolean`.
  module Boolean; end

  # Holds the resolved prop values for a single component instance. Provides
  # `props.NAME` read-through lookup via method_missing that pulls the
  # current value from the host's `@NAME` Signal ivar (so updates via
  # `Component#update_prop` are reflected on next read).
  class Props
    NO_DEFAULT = Object.new.freeze
    ATTR_PREFIX = "data-prop-".freeze

    # Names whose `prop :X` declaration would collide with a framework ivar
    # set by Component#initialize / lifecycle. Rejected at declaration time.
    RESERVED_NAMES = %i[
      root refs parent props children exposed resources scope_stack
      prepare_setup_phase_done mounted unmounted
      error_handler abort_controller _prop_signals
    ].freeze

    # Bundles error-message context (attr_key + component_name) so converters
    # don't have to thread two extra args through every helper. Created per
    # successful attribute read in `build`.
    class ConversionContext
      attr_reader :attr_key, :component_name
      def initialize(attr_key, component_name)
        @attr_key = attr_key
        @component_name = component_name
      end
    end

    def initialize(values, host = nil)
      @values = values
      @host = host
    end

    def has?(name)
      @values.key?(name)
    end

    # Snapshot of all current prop values (scalars, not Signals).
    def to_h
      out = {}
      @values.each_key { |k| out[k] = current_value(k) }
      out
    end

    def respond_to_missing?(name, _include_private = false)
      @values.key?(name) || super
    end

    def method_missing(name, *args)
      if @values.key?(name) && args.empty?
        current_value(name)
      else
        super
      end
    end

    private

    # Pull from the host's auto-init Signal ivar if available (live value);
    # fall back to the stored scalar when @host is nil (empty fallback Props
    # used by prepare_setup_phase's rescue branch).
    def current_value(name)
      return @values[name] unless @host
      sig = @host.instance_variable_get(:"@#{name}")
      sig.is_a?(Signal) ? sig.value : @values[name]
    end

    class << self
      # Build a Props instance from declarations and the root element. Performs
      # type conversion, default application, missing-required raise, and
      # (dev_mode only) unknown `data-prop-*` warn.
      #
      # Side effects on `host`:
      #   - sets `@NAME` to a new `Signal.new(coerced_value)` for each prop
      #   - stores the original Signal references in `@_prop_signals` so the
      #     mount-time `validate_prop_ivars_not_overwritten!` can detect
      #     user reassignment via object-identity comparison
      def build(declarations, root_ref, component_name, host: nil)
        values = {}
        signals = {}
        # Install the signals Hash on the host BEFORE the loop so any raise
        # mid-iteration still leaves `@_prop_signals` referencing the
        # partial map — `validate_prop_ivars_not_overwritten!` then covers
        # the props that did succeed.
        host.instance_variable_set(:@_prop_signals, signals) if host
        declarations.each do |name, spec|
          attr_key = attr_key_for(name)
          raw = root_ref.attr(attr_key)
          if raw.nil?
            if spec[:default].equal?(NO_DEFAULT)
              raise Lilac::Error,
                    "required prop :#{name} is missing in component #{component_name} " \
                    "(declare default via `prop :#{name}, ..., default: ...`)"
            end
            value = spec[:default]
          else
            value = convert(
              type: spec[:type], raw: raw, name: name,
              ctx: ConversionContext.new(attr_key, component_name)
            )
          end
          values[name] = value
          if host
            sig = Signal.new(value)
            host.instance_variable_set(:"@#{name}", sig)
            signals[name] = sig
          end
        end
        warn_unknown(declarations, root_ref, component_name) if Lilac.dev_mode
        new(values, host)
      end

      # Public so Component / tests can build attribute keys the same way as
      # build / warn_unknown without re-implementing the kebab convention.
      def attr_key_for(name)
        "#{ATTR_PREFIX}#{name.to_s.tr('_', '-')}"
      end

      def name_from_attr_key(attr_key)
        attr_key.sub(ATTR_PREFIX, "").tr("-", "_").to_sym
      end

      # Public coercion entry point — same type rules as the per-prop
      # conversion inside `build`, callable for runtime prop updates.
      def coerce(raw, type, attr_key, component_name = "(unknown)", name: nil)
        convert(
          type: type, raw: raw, name: name,
          ctx: ConversionContext.new(attr_key, component_name)
        )
      end

      private

      def convert(type:, raw:, name:, ctx:)
        case
        when type.equal?(String)
          raw
        when type.equal?(Integer)
          try_convert(raw: raw, type_name: "Integer", ctx: ctx) { Integer(raw) }
        when type.equal?(Float)
          try_convert(raw: raw, type_name: "Float", ctx: ctx) { Float(raw) }
        when type.equal?(Lilac::Boolean)
          convert_boolean(raw: raw, ctx: ctx)
        else
          raise Lilac::Error,
                "unsupported prop type #{type} for :#{name} in #{ctx.component_name} " \
                "(supported: String / Integer / Float / Lilac::Boolean)"
        end
      end

      # Wrap a conversion block with uniform error formatting. The block does
      # the actual `Integer(raw)` / `Float(raw)` call; this helper only owns
      # the rescue + error message so adding a future numeric type means one
      # extra `when` branch, not a new helper.
      def try_convert(raw:, type_name:, ctx:)
        yield
      rescue ArgumentError, TypeError
        raise Lilac::Error,
              "#{ctx.attr_key}=#{raw.inspect} cannot be converted to #{type_name} " \
              "in component #{ctx.component_name}"
      end

      # "true" / "false" canonical, "" (HTML presence shortcut for both
      # <div data-prop-x> and <div data-prop-x="">) → true. Other strings
      # raise so typos like "yes" / "1" / "on" surface immediately.
      def convert_boolean(raw:, ctx:)
        case raw
        when "true", ""
          true
        when "false"
          false
        else
          raise Lilac::Error,
                "#{ctx.attr_key}=#{raw.inspect} is not a valid Boolean " \
                '(use "true" / "false" / presence shortcut) ' \
                "in component #{ctx.component_name}"
        end
      end

      # Dev-mode only: scan attributes for any `data-prop-*` not present in
      # the class's declarations and emit a warn (typo detection). Gated on
      # `Lilac.dev_mode` by the caller so production pages skip the
      # `getAttributeNames` iteration entirely.
      def warn_unknown(declarations, root_ref, component_name)
        names_js = root_ref.js.call(:getAttributeNames)
        n = names_js[:length].to_i
        i = 0
        while i < n
          raw_name = names_js[i].to_s
          if raw_name.start_with?(ATTR_PREFIX)
            ruby_name = name_from_attr_key(raw_name)
            unless declarations.key?(ruby_name)
              Lilac.logger.warn(
                "#{raw_name}=... on <#{component_name}> — " \
                "no `prop :#{ruby_name}` declared (typo?)"
              )
            end
          end
          i += 1
        end
      end
    end
  end
end
