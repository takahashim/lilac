# lilac.rb — Lilac module with reactive primitives + JS::Object mixins.
#
# Defines:
#   - module Lilac (top-level brand namespace)
#   - Lilac::Error
#   - Lilac.dev_mode / .logger / .__window__ / .batch
#   - Lilac::Logger (default writes to STDERR; override emit_warn / emit_error)
#   - Lilac::Reactive (private infrastructure: TRACKER, BATCH, helpers)
#   - Lilac::Subscribers
#   - Lilac::MutationGuard
#   - Lilac::Signal / Lilac::Computed / Lilac::Effect (user-facing types,
#     flat under Lilac — no Reactive:: in the path)
#
# Companion file lilac_component.rb adds Lilac::Component (the user's
# inheritance base), RefElement / Refs / Bindable / Registry, and the
# module-level facade (Lilac.start / register / find_for_element).

module Lilac
  class Error < StandardError; end

  # Raised by `Component#sleep` (and other lifecycle-aware awaits) when
  # the owning component has unmounted during the await — keeps the
  # resuming fiber from operating on a dead component. `StandardError`
  # parent (a la `Timeout::Error`) so the framework's existing
  # `rescue => e` boundaries catch it; `Logger#error` silently drops
  # Aborted at the top, bypassing `on_error` and stderr.
  #
  # Caveat: user-side bare `rescue => e` also catches Aborted —
  # re-raise it explicitly inside such a rescue to keep silence.
  class Aborted < StandardError; end

  # Validated name for HTML data-* attribute values that Lilac uses
  # as keys (data-component / data-template / data-ref). The pattern
  # matches identifier-like tokens that round-trip safely through CSS
  # attribute selectors (no quoting required) and method_missing
  # access. Acts as a value object — downstream code receiving
  # `AttrName` can skip re-validation.
  class AttrName
    VALID = /^[A-Za-z][A-Za-z0-9_-]*$/

    attr_reader :kind

    def initialize(str, kind:)
      @str = str.to_s
      @kind = kind
      raise Error,
            "Invalid #{@kind} name: #{@str.inspect}; must match [A-Za-z][A-Za-z0-9_-]*" unless VALID.match?(@str)
    end

    def to_s
      @str
    end
  end

  @dev_mode = true
  @logger = nil

  class << self
    attr_accessor :dev_mode

    def dev_mode?
      @dev_mode
    end

    # Returns the active logger, instantiating a default
    # `Lilac::Logger` on first access. `Lilac.logger = nil` clears
    # the override so the next read re-creates the default.
    def logger
      @logger ||= Logger.new
    end

    # Accepts a `Lilac::Logger` (or duck-typed object), a Proc (which
    # is auto-wrapped — receives `(severity, msg_or_label, err_or_nil)`),
    # or `nil` to reset to the default.
    def logger=(value)
      @logger = value.is_a?(Proc) ? Logger::ProcAdapter.new(value) : value
    end

    # Resolve the DOM window. In a browser, `window === globalThis`,
    # so `JS.global` is the window. Under the test runner we only
    # stamp `globalThis.document` and read constructors off
    # `document.defaultView` (the happy-dom Window). This indirection
    # lets us pick up window-scoped Event / CustomEvent /
    # MutationObserver classes without shadowing Node's globals.
    def __window__
      doc = JS.global[:document]
      view = doc[:defaultView]
      return view if !view.js_null?
      JS.global
    end
  end

  # Default logger. `warn(msg)` and `error(label, error, source:)` are
  # the public entry points used throughout the framework. Subclass and
  # override `emit_warn` / `emit_error` to redirect output (tests use
  # this to capture emissions into an array). `error` first bubbles
  # `label, error` up the `source` parent chain via `handle_error`; only
  # if no boundary absorbs it does `emit_error` actually run — see
  # docs/lilac-spec.md "Error Boundary".
  class Logger
    def warn(msg)
      return unless Lilac.dev_mode?
      emit_warn(msg)
    end

    def error(label, error, source: nil)
      # Lifecycle aborts are control-flow signals, not errors.
      return if error.is_a?(Lilac::Aborted)
      current = source
      while current
        return if current.handle_error(label, error)
        current = current.parent
      end
      emit_error(label, error)
    end

    # Browser-targeted output: route through `console.warn` /
    # `console.error` via the JS bridge. mruby-io / hal-wasi-io are
    # NOT pulled into the browser bundle, so `STDERR` is undefined here
    # and a direct `puts` would NameError. Tests / non-browser hosts
    # can still override emission via `Lilac.logger = ->(...) { ... }`.
    def emit_warn(msg)
      JS.global[:console].call(:warn, "[Lilac] #{msg}")
    end

    def emit_error(label, error)
      con = JS.global[:console]
      con.call(:error, "[Lilac] Error in #{label}")
      con.call(:error, "  #{error.class}: #{error.message}")
      return unless Lilac.dev_mode?
      bt = error.backtrace if error.respond_to?(:backtrace)
      bt&.each { |line| con.call(:error, "    #{line}") }
    end

    # Auto-installed when a user does `Lilac.logger = ->(s, m, e) { ... }`.
    # Forwards both severity channels into the single callable using the
    # legacy three-argument shape so existing test/debug snippets keep
    # working against the new Logger API.
    class ProcAdapter < Logger
      def initialize(callable)
        @callable = callable
      end

      def emit_warn(msg)
        @callable.call(:warn, msg, nil)
      end

      def emit_error(label, error)
        @callable.call(:error, label, error)
      end
    end
  end

  # Thin wrapper over `JS.global[:JSON]`. `generate` always feeds the
  # value through `JS.wrap` so nested Array<Hash> structures serialize
  # correctly (avoiding the `JS.object(non_hash)` pitfall). `parse`
  # always runs `to_ruby` so callers get a frozen Ruby value, not a
  # raw JS::Object.
  module JSON
    def self.parse(string)
      JS.global[:JSON].call(:parse, string.to_s).to_ruby
    end

    def self.generate(value)
      JS.global[:JSON].call(:stringify, JS.wrap(value)).to_s
    end
  end

  # Reactive infrastructure (private). The user-facing types Signal /
  # Computed / Effect are flattened to Lilac::* directly. This module
  # houses only the shared tracker stack and notify pipeline they
  # depend on.
  module Reactive
    TRACKER = {}
    BATCH = { depth: 0, queue: [] }

    class << self
      def tracker_stack
        fiber = Fiber.current
        key = fiber ? fiber.__id__ : :main
        TRACKER[key] ||= []
      end

      def track(observer, &block)
        raise ArgumentError, "block required" unless block
        stack = tracker_stack
        stack.push(observer)
        begin
          block.call
        ensure
          stack.pop
          TRACKER.delete(Fiber.current.__id__) if Fiber.current && stack.empty?
        end
      end

      # Run block with tracking suppressed (pushes nil onto TRACKER so
      # `current` reads as nil inside).
      def untrack
        stack = tracker_stack
        stack.push(nil)
        begin
          yield
        ensure
          stack.pop
          TRACKER.delete(Fiber.current.__id__) if Fiber.current && stack.empty?
        end
      end

      def current
        tracker_stack.last
      end

      # Notify a list of observers, respecting the active batch.
      def notify(observers)
        return if observers.empty?
        if BATCH[:depth] > 0
          BATCH[:queue].concat(observers)
          return
        end
        # Snapshot — observers may add/remove subscribers during run.
        # Dedup by object id since the same effect may be subscribed
        # via multiple signals.
        seen = {}
        observers.each do |o|
          next if seen[o.__id__]
          seen[o.__id__] = true
          o.notify
        end
      end

      def batch
        BATCH[:depth] += 1
        begin
          yield
        ensure
          BATCH[:depth] -= 1
          if BATCH[:depth] == 0
            queued = BATCH[:queue]
            BATCH[:queue] = []
            seen = {}
            queued.each do |o|
              next if seen[o.__id__]
              seen[o.__id__] = true
              o.notify
            end
          end
        end
      end
    end

    # Role mixin: a value that observers can subscribe to and that
    # broadcasts changes via `notify_subscribers`. Signal, Computed, and
    # SelectorEntry include this. Including class must set
    # `@subs = Subscribers.new` before any subscription call.
    module Subscribable
      def subscribe(observer)
        @subs.add(observer)
      end

      def unsubscribe(observer)
        @subs.remove(observer)
      end

      # Notify all current subscribers via `Reactive.notify` (respects
      # active batch). Public so a co-operating subject (e.g. a Selector
      # firing per-key entries) can trigger notification from outside.
      def notify_subscribers
        Reactive.notify(@subs.to_a)
      end
    end

    # Role mixin: a thing that observes Signal/Computed values and
    # reacts to their changes. Computed, Effect, ResourceObserver, and
    # Selector include this. Including class must initialize `@deps = []`
    # and implement `def notify; ...; end`.
    module Observer
      def add_dep(dep)
        @deps << dep
      end

      # Unsubscribe from every tracked dependency and clear the dep
      # list. Used by `dispose` and re-execution paths (Effect#run,
      # Computed#recompute) that re-collect deps from scratch.
      def remove_all_deps
        @deps.each { |d| d.unsubscribe(self) }
        @deps.clear
      end
    end
  end

  # Public shorthand: `Lilac.batch { ... }` matches the rest of the
  # module-level facade.
  class << self
    def batch(&block)
      raise ArgumentError, "block required" unless block
      Reactive.batch(&block)
    end
  end

  # Subscriber list with deterministic insertion order. `to_a` returns
  # a defensive dup so callers can iterate safely even if the
  # underlying list is mutated during notify.
  class Subscribers
    def initialize
      @list = []
    end

    def add(observer)
      return if @list.include?(observer)
      @list << observer
    end

    def remove(observer)
      @list.delete(observer)
    end

    def to_a
      @list.dup
    end
  end

  # Dev-mode helpers that detect common Signal misuse.
  module MutationGuard
    WARNINGS = {
      cannot_mutate_in_update:
        "Cannot mutate value inside update. Use mutate instead.",
      same_mutable:
        "update returned the same mutable object. " \
          "If you mutated it in place, use mutate instead.",
      returns_different_collection:
        "mutate ignores the block return value. " \
          "Use update if you want to return a new value.",
    }.freeze

    class << self
      def freeze_for_update(value)
        case value
        when Array, Hash, String then value.dup.freeze
        else value
        end
      end

      def mutable_collection?(v)
        v.is_a?(Array) || v.is_a?(Hash)
      end

      def assert_mutable!(value)
        return if mutable_collection?(value)
        raise TypeError,
              "mutate target must be Array or Hash, got #{type_name(value)}"
      end

      def detect_update_misuse(prev, arg, new_value)
        return :same_mutable if new_value.equal?(arg) && mutable_collection?(prev)
        nil
      end

      def detect_mutate_misuse(value, ret)
        return :returns_different_collection if !ret.equal?(value) && mutable_collection?(ret)
        nil
      end

      def frozen_error?(error)
        msg = error.message.to_s
        msg.include?("frozen") || msg.include?("can't modify")
      end

      def warn(symbol)
        msg = WARNINGS[symbol]
        Lilac.logger.warn(msg) if msg
      end

      def type_name(v)
        case v
        when Numeric then "Numeric"
        when Symbol then "Symbol"
        when true, false then "Boolean"
        when nil then "NilClass"
        else v.class.name.to_s
        end
      end
    end
  end

  # Writable reactive cell.
  class Signal
    include Reactive::Subscribable

    def initialize(initial)
      @value = initial
      @subs = Subscribers.new
    end

    def value
      if (obs = Reactive.current)
        subscribe(obs)
        obs.add_dep(self)
      end
      @value
    end

    def value=(new_value)
      return new_value if equal_for_skip?(@value, new_value)
      @value = new_value
      notify_subscribers
      new_value
    end

    def update(&block)
      raise ArgumentError, "block required" unless block
      prev = @value
      arg = MutationGuard.freeze_for_update(prev)
      begin
        new_value = block.call(arg)
      rescue => e
        MutationGuard.warn(:cannot_mutate_in_update) if MutationGuard.frozen_error?(e)
        raise
      end
      if Lilac.dev_mode?
        MutationGuard.warn(MutationGuard.detect_update_misuse(prev, arg, new_value))
      end
      @value = new_value
      notify_subscribers
      new_value
    end

    def mutate(&block)
      raise ArgumentError, "block required" unless block
      MutationGuard.assert_mutable!(@value)
      ret = block.call(@value)
      if Lilac.dev_mode?
        MutationGuard.warn(MutationGuard.detect_mutate_misuse(@value, ret))
      end
      notify_subscribers
      @value
    end

    private

    # Skip notify when `value=` is called with the same primitive.
    def equal_for_skip?(a, b)
      case a
      when Numeric, Symbol, true, false, nil, String then a == b
      else false
      end
    end
  end

  # Read-only derived signal.
  class Computed
    include Reactive::Subscribable
    include Reactive::Observer

    # Lazy: the block does NOT run at construction time. First `.value`
    # access triggers `recompute`, which subscribes to dependencies. This
    # lets users write `computed { form[:auto_registered_field].value }`
    # in setup — `form[:X]` doesn't exist yet (scanner auto-registers it
    # after setup returns) but the computed block won't fire until something
    # actually reads `.value` (typically a phase-B dispatch effect created
    # by data-text / data-class / ... after auto-register has completed).
    #
    # Side effects in computed blocks are an anti-pattern. If you need
    # them at construction time, use `effect { ... }` instead.
    def initialize(equals: nil, on: nil, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @equals = equals
      @on = normalize_on(on)
      @deps = []
      @subs = Subscribers.new
      @value = nil
      @computed_once = false
    end

    def value
      recompute_and_mark unless @computed_once
      if (obs = Reactive.current)
        subscribe(obs)
        obs.add_dep(self)
      end
      @value
    end

    def value=(_)
      raise NoMethodError, "Computed is read-only"
    end

    # Notified by a dependency. If we've never been read, no observer is
    # subscribed and the next `.value` read will recompute anyway, so
    # skip the eager re-run here. Once read at least once, behave as
    # before: recompute and notify downstream subscribers when the new
    # value differs.
    def notify
      return unless @computed_once
      prev = @value
      recompute
      notify_subscribers unless equal_for_skip?(prev, @value)
    end

    def dispose
      remove_all_deps
    end

    private

    def recompute_and_mark
      recompute
      @computed_once = true
    end

    def recompute
      remove_all_deps
      if @on
        Reactive.track(self) do
          @on.each { |dep| dep.value }
        end
        @value = Reactive.untrack { @block.call }
      else
        Reactive.track(self) do
          @value = @block.call
        end
      end
    end

    def equal_for_skip?(prev, next_value)
      return false if @equals == false
      return @equals.call(prev, next_value) if @equals.respond_to?(:call)
      prev == next_value
    end

    def normalize_on(on)
      return nil if on.nil?
      deps = on.is_a?(Array) ? on : [on]
      deps.each do |dep|
        next if dep.respond_to?(:value)
        raise ArgumentError, "computed on: entries must respond to #value"
      end
      deps
    end
  end

  # Side effect that re-runs whenever a tracked dependency changes.
  # `source:` (the owning Component, when created via Component#effect) is
  # consulted by `Lilac.logger.error` for on_error bubbling.
  class Effect
    include Reactive::Observer

    def initialize(label: nil, source: nil, &block)
      raise ArgumentError, "block required" unless block
      @block = block
      @label = label
      @source = source
      @deps = []
      @disposed = false
      run
    end

    def notify
      return if @disposed
      run
    end

    def dispose
      return if @disposed
      @disposed = true
      remove_all_deps
    end

    private

    def run
      remove_all_deps
      Reactive.track(self) do
        @block.call
      end
    rescue => e
      Lilac.logger.error("effect#{@label ? " (#{@label})" : ""}", e, source: @source)
    end
  end

end
