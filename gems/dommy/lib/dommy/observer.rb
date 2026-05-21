# frozen_string_literal: true

module Dommy
  # MutationRecord — produced for childList, attributes, or
  # characterData mutations and delivered to the observer callback.
  # Mirrors the browser MutationRecord interface; `oldValue` is only
  # populated when the observer asked for it via `attributeOldValue`
  # / `characterDataOldValue`.
  class MutationRecord
    def initialize(type:, target:, added_nodes: [], removed_nodes: [], attribute_name: nil, old_value: nil)
      @type = type
      @target = target
      @added_nodes = added_nodes
      @removed_nodes = removed_nodes
      @attribute_name = attribute_name
      @old_value = old_value
    end

    attr_reader :type, :target, :added_nodes, :removed_nodes, :attribute_name, :old_value

    def __js_get__(key)
      case key
      when "type"           then @type
      when "target"         then @target
      when "addedNodes"     then @added_nodes
      when "removedNodes"   then @removed_nodes
      when "attributeName"  then @attribute_name
      when "oldValue"       then @old_value
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
      end
    end

    # Used by Document#notify_*_mutation to decide if a given target
    # falls within this observer's scope (target node itself, or any
    # descendant if subtree was requested).
    def matches?(target)
      observer_entry(target) != nil
    end

    # Resolve the matching `observed` entry — caller needs the entry
    # to know which options (attributeFilter, attributeOldValue, etc.)
    # apply to a mutation.
    def observer_entry(target)
      target_node = target.respond_to?(:__node__) ? target.__node__ : target
      @observed.find do |entry|
        observed = entry[:target]
        next false unless observed

        observed_node = observed.respond_to?(:__node__) ? observed.__node__ : observed
        if observed_node.is_a?(Document)
          # Document observation matches if target is anywhere in
          # the document tree (when subtree:true) or is the document
          # itself.
          target == observed || (entry[:subtree] && target_node.is_a?(Nokogiri::XML::Node))
        else
          target_node == observed_node ||
            (entry[:subtree] && descendant_of?(target_node, observed_node))
        end
      end
    end

    def enqueue(record)
      @records << record
      return nil if @scheduled

      @scheduled = true
      @window.scheduler.queue_microtask(proc { flush })
      nil
    end

    # Public: introspection used by linkedom-style tests that peek at
    # pending records without draining (`observer.records[0]`).
    def records
      @records.dup
    end

    private

    def observe(target, options)
      opts = options.is_a?(Hash) ? options : {}
      attribute_filter = opts["attributeFilter"] || opts[:attributeFilter]
      attribute_filter = attribute_filter.map { |s| s.to_s.downcase } if attribute_filter.is_a?(Array)
      # `attributes: true` is implied if attributeFilter / attributeOldValue
      # is supplied; `characterData: true` is implied if
      # characterDataOldValue is supplied. Matches the spec's option
      # normalization in MutationObserverInit.
      attrs_implied = !attribute_filter.nil? || truthy_option(opts, "attributeOldValue")
      char_implied = truthy_option(opts, "characterDataOldValue")
      attributes_on = truthy_option(opts, "attributes") || attrs_implied
      child_list_on = truthy_option(opts, "childList")
      character_data_on = truthy_option(opts, "characterData") || char_implied

      # Per spec, observe() must request at least one of childList,
      # attributes, or characterData; otherwise TypeError.
      unless child_list_on || attributes_on || character_data_on
        raise TypeError, "MutationObserver.observe: at least one of childList, attributes, characterData must be true"
      end

      @observed << {
        target: target,
        child_list: child_list_on,
        subtree: truthy_option(opts, "subtree"),
        attributes: attributes_on,
        attribute_filter: attribute_filter,
        attribute_old_value: truthy_option(opts, "attributeOldValue"),
        character_data: character_data_on,
        character_data_old_value: truthy_option(opts, "characterDataOldValue"),
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
      current = node.respond_to?(:parent) ? node.parent : nil
      while current && !current.is_a?(Nokogiri::XML::Document)
        return true if current == ancestor

        current = current.respond_to?(:parent) ? current.parent : nil
      end
      false
    end

    def truthy_option(hash, key)
      value = hash[key] || hash[key.to_sym]
      value == true || value.to_s == "true"
    end
  end
end
