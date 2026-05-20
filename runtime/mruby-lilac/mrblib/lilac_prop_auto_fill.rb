module Lilac
  # Populates child component props from the current iteration item
  # when no explicit `data-prop-X` is written. Lives in `mruby-lilac`
  # core (not the scanner gem) so the `lilac-compiled` target — which
  # excludes the scanner — can also auto-fill via `bind_list`'s row
  # hook.
  #
  # Entry points:
  #
  #   - `fill_attributes(el, item)` — first mount: writes
  #       `data-prop-X="<item[X]>"` attributes onto the DOM element so
  #       the about-to-be-mounted child's `Props.build` reads them as
  #       if the user had typed them.
  #   - `push_updates(row_node, item, skip_exprs, host:)` — row reuse:
  #       the child is already mounted; push fresh values directly
  #       into its prop Signals via `update_prop`. `skip_exprs` is the
  #       set of attribute names that an explicit data-prop-X / it.X
  #       expression already covers (so we don't double-push).
  #   - `fill_row(root_js, item)` / `push_row_updates(root_js, item, host:)`
  #       — convenience entry points for `bind_list`: walk a row's
  #       subtree and apply the above to every data-component
  #       descendant (including the row root itself).
  #
  # `host:` is the parent component, used only as the source for
  # `Lilac.logger.error` so the diagnostic frame points at the right
  # owner. Both methods are no-ops when the child class can't be
  # resolved, when the child has no `prop` declarations, or when the
  # item lacks a key matching a given prop name.
  module PropAutoFill
    class << self
      def fill_attributes(el, item)
        return if item.nil?
        klass = resolve_class(el)
        return unless klass
        klass.prop_declarations.each_key do |prop_name|
          attr_key = attr_key_for(prop_name)
          next if el.call(:hasAttribute, attr_key).js_bool
          field_value = ItemField.read(item, prop_name)
          next if field_value.nil?
          el.call(:setAttribute, attr_key, field_value.to_s)
        end
      end

      def push_updates(row_node, item, skip_exprs, host:)
        child = Lilac.find_for_element(row_node)
        return unless child && child.respond_to?(:update_prop)
        klass = child.class
        return unless klass.respond_to?(:prop_declarations)
        explicit = explicit_prop_set(skip_exprs)
        klass.prop_declarations.each_key do |prop_name|
          next if explicit[prop_name]
          field_value = ItemField.read(item, prop_name)
          next if field_value.nil?
          begin
            child.update_prop(prop_name, field_value.to_s)
          rescue Lilac::Error => e
            Lilac.logger.error("data-prop auto-fill reuse :#{prop_name}", e, source: host)
          end
        end
      end

      # Pre-mount entry for bind_list: writes data-prop-X attributes on
      # every data-component descendant of `root_js` (including root)
      # so the about-to-mount children read them in `Props.build`.
      def fill_row(root_js, item)
        each_data_component(root_js) { |el| fill_attributes(el, item) }
      end

      # Row-reuse entry for bind_list: the children are already
      # mounted; push fresh prop values directly into their Signals.
      # `skip_exprs` is always empty for the codegen path (explicit
      # `data-prop-X` expressions are a scanner-only `data-each`
      # feature).
      def push_row_updates(root_js, item, host:)
        each_data_component(root_js) do |el|
          push_updates(el, item, {}, host: host)
        end
      end

      private

      # Pre-order DFS over a detached fragment / live subtree, yielding
      # every element that carries `data-component`. Visits the node
      # itself first so a row whose own root IS the data-component
      # (the common 7guis shape) is covered.
      def each_data_component(node, &block)
        if node.call(:hasAttribute, "data-component").js_bool
          yield node
        end
        kids = node[:children]
        n = kids[:length].to_i
        i = 0
        while i < n
          each_data_component(kids[i], &block)
          i += 1
        end
      end

      def resolve_class(el)
        comp_name_raw = el.call(:getAttribute, "data-component")
        return nil if comp_name_raw.js_null?
        comp_name = comp_name_raw.to_s
        return nil if comp_name.empty?
        klass = Lilac.registry.find_component_class(comp_name)
        return nil unless klass && klass.respond_to?(:prop_declarations)
        klass
      end

      def attr_key_for(prop_name)
        "data-prop-#{prop_name.to_s.tr('_', '-')}"
      end

      def explicit_prop_set(skip_exprs)
        out = {}
        skip_exprs.each_key do |attr_name|
          name = attr_name.sub("data-prop-", "").tr("-", "_").to_sym
          out[name] = true
        end
        out
      end
    end
  end

  # Back-compat alias for the scanner gem (mruby-lilac-directives) which
  # historically references the module via the `Directives` namespace.
  module Directives
    PropAutoFill = ::Lilac::PropAutoFill
  end
end
