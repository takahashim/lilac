# frozen_string_literal: true

class MrubyWasm
  module Dom
    class MutationRecord
      def initialize(target:, added_nodes:, removed_nodes:)
        @target = target
        @added_nodes = added_nodes
        @removed_nodes = removed_nodes
      end

      def __js_get__(key)
        case key
        when "type" then "childList"
        when "target" then @target
        when "addedNodes" then @added_nodes
        when "removedNodes" then @removed_nodes
        else nil
        end
      end
    end

    class MutationObserver
      def initialize(window, callback)
        @window = window
        @document = window.document
        @callback = callback
        @observed = []
        @records = []
        @scheduled = false
      end

      def __js_call__(method, args)
        case method
        when "observe"
          observe(args[0], args[1])
        when "disconnect"
          disconnect
        when "takeRecords"
          take_records
        else
          nil
        end
      end

      def matches?(target)
        @observed.any? do |entry|
          observed = entry[:target]
          next false unless observed

          observed_node = observed.__node__
          target_node = target.__node__
          target_node == observed_node || (entry[:subtree] && descendant_of?(target_node, observed_node))
        end
      end

      def enqueue(record)
        @records << record
        return nil if @scheduled

        @scheduled = true
        @window.scheduler.queue_microtask(proc { flush })
        nil
      end

      private

      def observe(target, options)
        opts = options.is_a?(Hash) ? options : {}
        @observed << {
          target: target,
          child_list: truthy_option(opts, "childList"),
          subtree: truthy_option(opts, "subtree"),
        }
        @document.register_observer(self)
        nil
      end

      def disconnect
        @records.clear
        @scheduled = false
        @observed.clear
        @document.unregister_observer(self)
        nil
      end

      def take_records
        out = @records.dup
        @records.clear
        @scheduled = false
        out
      end

      def flush
        @scheduled = false
        return if @records.empty?

        records = @records.dup
        @records.clear
        if @callback.respond_to?(:__js_call__)
          @callback.__js_call__("call", [records])
        elsif @callback.respond_to?(:call)
          @callback.call(records)
        end
      end

      def descendant_of?(node, ancestor)
        current = node.parent
        while current
          return true if current == ancestor

          current = current.parent
        end
        false
      end

      def truthy_option(hash, key)
        value = hash[key] || hash[key.to_sym]
        value == true || value.to_s == "true"
      end
    end
  end
end
