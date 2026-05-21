# frozen_string_literal: true

module Dommy
  class Callback
    def initialize(host, callback_id)
      @host = host
      @callback_id = callback_id
      @props = {}
    end

    def __js_get__(key)
      case key
      when "__mruby_cb_id__"
        @props.fetch(key, @callback_id)
      else
        @props[key]
      end
    end

    def __js_set__(key, value)
      @props[key] = value
      nil
    end

    def __js_call__(method, args)
      case method
      when "call"
        @host.invoke_callback(@callback_id, args)
      else
        nil
      end
    end
  end

  class Constructor
    def initialize(&block)
      @block = block
    end

    def __js_new__(args)
      @block.call(args)
    end
  end

  module EventTarget
    def add_event_listener(type, listener = nil, options = nil, &block)
      cb = listener || block
      return nil if type.nil? || cb.nil?

      list = listeners_for(type.to_s)
      # Per spec, the same listener (by identity) registered on the
      # same type is silently deduplicated.
      return nil if list.any? { |entry| entry.listener.equal?(cb) }

      list << Listener.new(cb, options)

      # `{ signal: AbortSignal }` — when the signal aborts, auto-
      # remove the listener. Per spec, if the signal is already aborted
      # the listener must not be registered at all.
      signal = options.is_a?(Hash) ? (options["signal"] || options[:signal]) : nil
      if signal.respond_to?(:__js_get__)
        if signal.__js_get__("aborted")
          remove_event_listener(type, cb)
        else
          target = self
          signal.__js_call__("addEventListener", ["abort", proc {
            target.remove_event_listener(type, cb)
          }])
        end
      end
      nil
    end

    def remove_event_listener(type, listener)
      return nil if type.nil? || listener.nil?

      listeners_for(type.to_s).reject! { |entry| entry.listener.equal?(listener) }
      nil
    end

    def dispatch_event(event)
      return true if event.nil?

      # Per spec, dispatchEvent must receive an Event instance.
      raise TypeError, "dispatchEvent requires an Event, got #{event.class}" unless event.is_a?(Event)

      event.__prepare_for_dispatch__(self)
      path = if event.bubbles?
               event.__js_get__("composed") ? composed_bubble_path(event) : event_bubble_path
             else
               [self]
             end
      event.__record_path__(path) if event.respond_to?(:__record_path__)
      path.each do |target|
        event.__set_current_target__(target)
        target.__deliver_event__(event)
        break if event.propagation_stopped?
      end
      !event.default_prevented?
    end

    def __deliver_event__(event)
      listeners = listeners_for(event.type).dup
      listeners.each do |entry|
        invoke_listener(entry.listener, event)
        if entry.once?
          listeners_for(event.type).reject! { |candidate| candidate.listener.equal?(entry.listener) }
        end
        break if event.immediate_propagation_stopped?
      end
      nil
    end

    private

    Listener = Struct.new(:listener, :options) do
      def once?
        case options
        when Hash
          options["once"] || options[:once]
        else
          false
        end
      end
    end

    def listeners_for(type)
      @event_listeners ||= Hash.new { |h, k| h[k] = [] }
      @event_listeners[type]
    end

    def event_bubble_path
      path = [self]
      current = self
      while (current = current.send(:__event_parent__))
        path << current
      end
      path
    end

    # Build the propagation path with optional shadow-boundary
    # crossing. When the in-flight event has `composed: true`, the
    # walk continues from a ShadowRoot to its host; otherwise it
    # stops at the shadow boundary (nil from `__event_parent__`).
    def composed_bubble_path(event)
      path = [self]
      current = self
      loop do
        nxt = current.send(:__event_parent__)
        if nxt.nil? && event.respond_to?(:__js_get__) && event.__js_get__("composed")
          # Try to cross a shadow boundary: if current is a node
          # inside a ShadowRoot, jump to its host.
          sr = enclosing_shadow_root_of(current)
          break unless sr

          nxt = sr.host
        end
        break unless nxt

        path << nxt
        current = nxt
      end
      path
    end

    private

    def enclosing_shadow_root_of(target)
      doc = nil
      doc = target.document if target.respond_to?(:document)
      doc ||= target.respond_to?(:__node__) && target.__node__.respond_to?(:document) ? Dommy::Document : nil
      return nil unless target.respond_to?(:__node__)

      doc_obj = target.instance_variable_get(:@document)
      return nil unless doc_obj.respond_to?(:__shadow_root_containing__)

      doc_obj.__shadow_root_containing__(target.__node__)
    end

    public

    def invoke_listener(listener, event)
      # DOM spec: a listener can be (a) a function, or (b) an object
      # with a `handleEvent` method. Both Ruby and JS-bridged callables
      # are supported.
      if listener.respond_to?(:handle_event)
        listener.handle_event(event)
      elsif listener.respond_to?(:call) && !listener.is_a?(Module)
        listener.call(event)
      elsif listener.respond_to?(:__js_call__)
        # Prefer handleEvent if the bridge object advertises it; fall
        # back to call. We can't introspect on the JS side, so we just
        # try call (the common case for JS.callback {}).
        listener.__js_call__("call", [event])
      end
    end
  end

  class StandaloneEventTarget
    include EventTarget

    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      else
        nil
      end
    end

    def __event_parent__
      nil
    end
  end

  class Event
    def initialize(type, init = nil)
      @type = type.to_s
      @bubbles = !!read_init(init, "bubbles")
      @cancelable = !!read_init(init, "cancelable")
      @composed = !!read_init(init, "composed")
      @default_prevented = false
      @propagation_stopped = false
      @immediate_propagation_stopped = false
      @target = nil
      @current_target = nil
      @composed_path = []
      # `timeStamp` is the high-resolution timestamp at construction
      # in ms (browser uses performance.now). We use monotonic time
      # for determinism across spec runs.
      @time_stamp = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0)
    end

    attr_reader :type

    def bubbles?
      @bubbles
    end

    def default_prevented?
      @default_prevented
    end

    def propagation_stopped?
      @propagation_stopped
    end

    def immediate_propagation_stopped?
      @immediate_propagation_stopped
    end

    def __prepare_for_dispatch__(target)
      @target ||= target
    end

    def __set_current_target__(target)
      @current_target = target
    end

    def __js_get__(key)
      case key
      when "type"             then @type
      when "bubbles"          then @bubbles
      when "cancelable"       then @cancelable
      when "composed"         then @composed
      when "defaultPrevented" then @default_prevented
      when "target"           then @target
      when "currentTarget"    then @current_target
      when "timeStamp"        then @time_stamp
      when "cancelBubble"     then @propagation_stopped
      when "eventPhase"       then event_phase
      end
    end

    def __js_set__(key, value)
      case key
      when "cancelBubble"
        # Setting to truthy stops propagation; spec quirk that
        # `cancelBubble = false` does NOT un-stop (browser observation).
        @propagation_stopped = true if value
      end
      nil
    end

    def __js_call__(method, args)
      case method
      when "preventDefault"
        @default_prevented = true if @cancelable
        nil
      when "stopPropagation"
        @propagation_stopped = true
        nil
      when "stopImmediatePropagation"
        @propagation_stopped = true
        @immediate_propagation_stopped = true
        nil
      when "composedPath"
        @composed_path.dup
      when "initEvent"
        init_event(args[0], args[1], args[2])
      end
    end

    # Deprecated `Event#initEvent(type, bubbles, cancelable)` — older
    # browsers used `document.createEvent("Event").initEvent(...)`.
    # Resets internal flags as a side effect.
    def init_event(type, bubbles = false, cancelable = false)
      @type = type.to_s
      @bubbles = !!bubbles
      @cancelable = !!cancelable
      @default_prevented = false
      @propagation_stopped = false
      @immediate_propagation_stopped = false
      nil
    end

    # Filled in by EventTarget#dispatch_event as the event walks the
    # bubble path so `composedPath()` returns the right list.
    #
    # Per spec, `load` events do not propagate to the Window when
    # composed paths are computed (resource-finished signal stays at
    # the target).
    def __record_path__(targets)
      @composed_path = if @type == "load"
                         targets.reject { |t| t.is_a?(Window) }
                       else
                         targets
                       end
    end

    private

    def event_phase
      # 0 = NONE (default), 2 = AT_TARGET, 3 = BUBBLING_PHASE. We don't
      # implement capturing (phase 1) by design.
      return 0 if @current_target.nil?
      return 2 if @current_target.equal?(@target)

      3
    end

    public

    private

    def read_init(init, key)
      case init
      when Hash
        init[key] || init[key.to_sym]
      else
        init.respond_to?(:__js_get__) ? init.__js_get__(key) : nil
      end
    end
  end

  class CustomEvent < Event
    def initialize(type, init = nil)
      super
      @detail = read_init(init, "detail")
    end

    def __js_get__(key)
      return @detail if key == "detail"

      super
    end
  end

  class MouseEvent < Event
    def initialize(type, init = nil)
      super
      @button = read_init(init, "button") || 0
      @ctrl_key = !!read_init(init, "ctrlKey")
      @shift_key = !!read_init(init, "shiftKey")
      @alt_key = !!read_init(init, "altKey")
      @meta_key = !!read_init(init, "metaKey")
      @client_x = read_init(init, "clientX") || 0
      @client_y = read_init(init, "clientY") || 0
    end

    def __js_get__(key)
      case key
      when "button" then @button
      when "ctrlKey" then @ctrl_key
      when "shiftKey" then @shift_key
      when "altKey" then @alt_key
      when "metaKey" then @meta_key
      when "clientX" then @client_x
      when "clientY" then @client_y
      else
        super
      end
    end
  end

  class KeyboardEvent < Event
    def initialize(type, init = nil)
      super
      @key = read_init(init, "key").to_s
      @ctrl_key = !!read_init(init, "ctrlKey")
      @shift_key = !!read_init(init, "shiftKey")
      @alt_key = !!read_init(init, "altKey")
      @meta_key = !!read_init(init, "metaKey")
    end

    def __js_get__(key)
      case key
      when "key" then @key
      when "ctrlKey" then @ctrl_key
      when "shiftKey" then @shift_key
      when "altKey" then @alt_key
      when "metaKey" then @meta_key
      else
        super
      end
    end
  end

  # `AbortController` + `AbortSignal` subset used by
  # `Lilac::Component#abort_signal`. Signal fires an "abort" event
  # and flips `[:aborted]` to true when the controller's `abort()`
  # is called; otherwise it stays inert.
  class AbortSignal
    include EventTarget

    def initialize
      @aborted = false
      @reason = nil
    end

    def __js_get__(key)
      case key
      when "aborted" then @aborted
      when "reason"  then @reason
      end
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __mark_aborted__(reason = nil)
      return if @aborted

      @aborted = true
      @reason = reason
      dispatch_event(Event.new("abort", "bubbles" => false, "cancelable" => false))
    end
  end

  class AbortController
    attr_reader :signal

    def initialize
      @signal = AbortSignal.new
    end

    def __js_get__(key)
      @signal if key == "signal"
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "abort"
        @signal.__mark_aborted__(args[0])
      end
    end
  end
end
