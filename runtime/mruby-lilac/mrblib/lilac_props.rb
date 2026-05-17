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

  # Holds the resolved prop Signals for a single component instance.
  # `props.NAME` returns the Signal's current value (= live, reflects
  # `Component#update_prop` calls). Component reads `props.signals` once
  # at mount time to install matching `@NAME` ivars and record them for
  # override detection.
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

    def initialize(signals = {})
      @signals = signals
    end

    # Internal: the underlying `name => Signal` map. Component reads this
    # once at mount to install ivars (`@NAME = signal`) and record them
    # for override detection. Treat as read-only — mutate values via
    # `Component#update_prop`, not by reaching in here.
    attr_reader :signals

    def has?(name)
      @signals.key?(name)
    end

    # Snapshot of all current prop values (scalars, not Signals).
    def to_h
      out = {}
      @signals.each { |k, sig| out[k] = sig.value }
      out
    end

    def respond_to_missing?(name, _include_private = false)
      @signals.key?(name) || super
    end

    def method_missing(name, *args)
      if @signals.key?(name) && args.empty?
        @signals[name].value
      else
        super
      end
    end

    class << self
      # Build a Props instance from declarations and the root element. Performs
      # type conversion, default application, missing-required raise, and
      # (dev_mode only) unknown `data-prop-*` warn.
      #
      # Returns a Props holding a fresh Signal per declared prop. No side
      # effects on any component — the caller (Component#prepare_setup_phase)
      # owns installing the Signals as `@NAME` ivars.
      def build(declarations, root_ref, component_name)
        signals = {}
        declarations.each do |name, spec|
          attr_key = attr_key_for(name)
          raw = root_ref.attr(attr_key)
          value =
            if raw.nil?
              if spec[:default].equal?(NO_DEFAULT)
                raise Lilac::Error,
                      "required prop :#{name} is missing in component #{component_name} " \
                      "(declare default via `prop :#{name}, ..., default: ...`)"
              end
              spec[:default]
            else
              convert(
                type: spec[:type], raw: raw, name: name,
                ctx: ConversionContext.new(attr_key, component_name)
              )
            end
          signals[name] = Signal.new(value)
        end
        warn_unknown(declarations, root_ref, component_name) if Lilac.dev_mode
        new(signals)
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
