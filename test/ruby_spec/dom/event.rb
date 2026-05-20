# frozen_string_literal: true

class MrubyWasm
  module Dom
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
      def add_event_listener(type, listener, options = nil)
        return nil if type.nil? || listener.nil?

        listeners_for(type.to_s) << Listener.new(listener, options)
        nil
      end

      def remove_event_listener(type, listener)
        return nil if type.nil? || listener.nil?

        listeners_for(type.to_s).reject! { |entry| entry.listener.equal?(listener) }
        nil
      end

      def dispatch_event(event)
        return true unless event

        event.__prepare_for_dispatch__(self)
        path = event.bubbles? ? event_bubble_path : [self]
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

      def invoke_listener(listener, event)
        if listener.respond_to?(:call)
          listener.call(event)
        elsif listener.respond_to?(:__js_call__)
          listener.__js_call__("call", [event])
        end
      end
    end

    class Event
      def initialize(type, init = nil)
        @type = type.to_s
        @bubbles = !!read_init(init, "bubbles")
        @cancelable = !!read_init(init, "cancelable")
        @default_prevented = false
        @propagation_stopped = false
        @immediate_propagation_stopped = false
        @target = nil
        @current_target = nil
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
        when "type"
          @type
        when "bubbles"
          @bubbles
        when "cancelable"
          @cancelable
        when "defaultPrevented"
          @default_prevented
        when "target"
          @target
        when "currentTarget"
          @current_target
        else
          nil
        end
      end

      def __js_call__(method, _args)
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
        else
          nil
        end
      end

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
  end
end
