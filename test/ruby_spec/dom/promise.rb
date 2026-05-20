# frozen_string_literal: true

class MrubyWasm
  module Dom
    class ErrorValue
      def initialize(message = nil, name: "Error")
        @message = message.to_s
        @name = name
      end

      def __js_get__(key)
        case key
        when "message" then @message
        when "name" then @name
        else nil
        end
      end

      def to_s
        return @name if @message.empty?

        "#{@name}: #{@message}"
      end
    end

    class PromiseConstructor
      def initialize(window)
        @window = window
      end

      def __js_call__(method, args)
        case method
        when "resolve"
          PromiseValue.resolve(@window, args[0])
        when "reject"
          PromiseValue.reject(@window, args[0])
        else
          nil
        end
      end
    end

    class PromiseValue
      Handler = Struct.new(:on_fulfilled, :on_rejected, :child)

      def self.resolve(window, value)
        promise = new(window)
        promise.fulfill(value)
        promise
      end

      def self.reject(window, reason)
        promise = new(window)
        promise.reject(reason)
        promise
      end

      def initialize(window)
        @window = window
        @state = :pending
        @value = nil
        @handlers = []
      end

      def __js_call__(method, args)
        case method
        when "then"
          attach_then(args[0], args[1])
        when "catch"
          attach_then(nil, args[0])
        else
          nil
        end
      end

      def fulfill(value)
        settle(:fulfilled, value)
      end

      def reject(reason)
        settle(:rejected, reason)
      end

      private

      def attach_then(on_fulfilled, on_rejected)
        child = self.class.new(@window)
        @handlers << Handler.new(on_fulfilled, on_rejected, child)
        schedule_flush if settled?
        child
      end

      def settle(state, value)
        return self if settled?

        if value.is_a?(PromiseValue)
          return adopt(value)
        end

        @state = state
        @value = value
        schedule_flush
        self
      end

      def adopt(other)
        other.__js_call__(
          "then",
          [
            proc { |resolved| fulfill(resolved) },
            proc { |reason| reject(reason) },
          ],
        )
        self
      end

      def settled?
        @state != :pending
      end

      def schedule_flush
        @window.scheduler.queue_microtask(proc { flush_handlers })
        nil
      end

      def flush_handlers
        return unless settled?
        return if @handlers.empty?

        handlers = @handlers.dup
        @handlers.clear
        handlers.each do |handler|
          run_handler(handler)
        end
      end

      def run_handler(handler)
        callback = @state == :fulfilled ? handler.on_fulfilled : handler.on_rejected
        if callback.nil?
          propagate(handler.child)
          return
        end

        result = invoke_callback(callback, @value)
        if result.is_a?(PromiseValue)
          result.__js_call__(
            "then",
            [
              proc { |resolved| handler.child.fulfill(resolved) },
              proc { |reason| handler.child.reject(reason) },
            ],
          )
        else
          handler.child.fulfill(result)
        end
      rescue => e
        handler.child.reject(ErrorValue.new(e.message, name: e.class.to_s))
      end

      def propagate(child)
        @state == :fulfilled ? child.fulfill(@value) : child.reject(@value)
      end

      def invoke_callback(callback, value)
        if callback.respond_to?(:__js_call__)
          callback.__js_call__("call", [value])
        else
          callback.call(value)
        end
      end
    end
  end
end
