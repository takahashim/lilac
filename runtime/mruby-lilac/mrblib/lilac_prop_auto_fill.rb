module Lilac
  module Directives
    # Populates child component props from the current iteration item
    # when no explicit `data-prop-X` is written. Two entry points cover
    # the data-each lifecycle:
    #
    #   - `fill_attributes(el, item, host:)`  — first mount: writes
    #       `data-prop-X="<item[X]>"` attributes onto the DOM element so
    #       the about-to-be-mounted child's `Props.build` reads them as
    #       if the user had typed them.
    #   - `push_updates(row_node, item, skip_exprs, host:)` — row reuse:
    #       the child is already mounted; push fresh values directly
    #       into its prop Signals via `update_prop`. `skip_exprs` is the
    #       set of attribute names that an explicit data-prop-X / it.X
    #       expression already covers (so we don't double-push).
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

        private

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
  end
end
