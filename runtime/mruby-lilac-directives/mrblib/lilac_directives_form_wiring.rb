# lilac_directives_form_wiring.rb — form-related dispatch / wire / scope
# resolution for the directive Scanner. Extracted from
# `lilac_directives_scanner.rb` to keep the main Scanner focused on
# directive extraction + phased dispatch orchestration; this module owns
# everything that knows about `data-form` / `data-field` / `data-button`
# and the corresponding `Lilac::Form` interactions.
#
# Included (not subclassed) into Scanner so the methods share the same
# instance state — `@host`, `@default_form_seen`, `@input_form_attr_warned`,
# `wrap_ref` — without a back-reference dance. The state lives on Scanner;
# this module is purely a code-organisation split.

module Lilac
  module Directives
    module FormWiring
      # ---- <form> element side effects (collected during DOM walk) ------

      # A second plain `<form>` (no data-form attribute) within the same
      # component subtree collides on the `:default` scope.
      def validate_form_element!(tag, attrs, descriptor)
        return if attrs.key?("data-form")
        if @default_form_seen
          raise Lilac::Error,
                "second plain <form> in same component would collide on :default scope " \
                "(use `<form data-form=\"...\">` to distinguish, #{descriptor})"
        end
        @default_form_seen = true
      end

      # `<input form="...">` is the HTML standard cross-form association
      # attribute, but Lilac scopes are ancestor-walk only. Warn once per
      # scan so the user knows the attribute is ignored by Lilac. Native
      # browser submit still honours the attribute; only Lilac state ignores it.
      def warn_on_form_attr(tag, attrs)
        return unless %w[input textarea select button].include?(tag)
        return if @input_form_attr_warned
        Lilac.logger.warn(
          "<#{tag} form=#{attrs['form'].inspect}>: Lilac does not resolve scope via " \
          "the HTML `form` attribute (ancestor <form> only). Attribute is left for " \
          "browser native submit; Lilac state ignores it."
        )
        @input_form_attr_warned = true
      end

      # ---- <form>: submit auto-wire ------------------------------------

      # Wire the form element's submit event to invoke_button(:submit) when
      # the resolved Form has a :submit button registered. preventDefault is
      # always called so the browser doesn't navigate.
      def wire_form_submit(form_el, attrs)
        form_name = attrs["data-form"]
        sym = (form_name && !form_name.empty?) ? form_name.to_sym : :default
        host = @host
        ref = wrap_ref(form_el)
        ref.on(:submit) do |event|
          event.call(:preventDefault)
          f = host.form(sym)
          next unless f.has_button?(:submit)
          f.invoke_button(:submit, event)
        end
      end

      # ---- data-field dispatch -----------------------------------------

      # Resolve enclosing form, ensure field is registered (auto-register
      # from HTML when Ruby didn't declare it), then wire the input + UI.
      def dispatch_field(raw_value, el)
        sym = parse_ident!(raw_value, "data-field")
        form = resolve_form_for(el)
        input_el = find_form_control(el)
        field = ensure_field_registered(form, sym, input_el)
        field.bind_to(wrap_ref(input_el)) if input_el
        wire_field_ui(field, el)
      end

      # Return the field registered under `sym`, auto-registering from HTML
      # (form-spec §10.3.1) when Ruby didn't declare it.
      def ensure_field_registered(form, sym, input_el)
        auto_register_field(form, sym, input_el) unless form.has_field?(sym)
        form[sym]
      end

      # All UI wiring tied to a `data-field` container: invalid/valid class
      # toggling and the optional error slot. Skips class wiring when the
      # author opts out via `data-field-no-class`.
      def wire_field_ui(field, container_el)
        unless container_el.call(:hasAttribute, "data-field-no-class").js_bool
          wire_field_container_class(field, container_el)
        end
        wire_field_error_slot(field, container_el)
      end

      # Container class wiring per form-spec §10.4. is-invalid toggles on
      # show_error?; is-valid toggles on touched? && valid?. Class names are
      # customizable via data-field-invalid / data-field-valid so design
      # systems with their own conventions can re-route without patching.
      def wire_field_container_class(field, container_el)
        invalid_attr = container_el.call(:getAttribute, "data-field-invalid")
        valid_attr   = container_el.call(:getAttribute, "data-field-valid")
        invalid_class = invalid_attr.js_null? ? "is-invalid" : invalid_attr.to_s
        valid_class   = valid_attr.js_null?   ? "is-valid"   : valid_attr.to_s
        host = @host
        @host.bind(wrap_ref(container_el), class: {
          invalid_class => host.computed { field.show_error? },
          valid_class   => host.computed { field.touched? && field.valid? },
        })
      end

      # Error slot per form-spec §10.4. Discovery priority:
      #   1. element with [data-field-error] within the container
      #   2. first descendant matching `.error`
      #   3. none → silent (some designs don't render per-field error text)
      # When found: bind textContent to error_signal, hidden attr to
      # !show_error?.
      def wire_field_error_slot(field, container_el)
        slot = container_el.call(:querySelector, "[data-field-error]")
        slot = container_el.call(:querySelector, ".error") if slot.js_null?
        return if slot.js_null?
        host = @host
        @host.bind(wrap_ref(slot),
                   text: field.error_signal,
                   attr: { "hidden" => host.computed { !field.show_error? } })
      end

      # ---- data-button dispatch ----------------------------------------

      # Look up the declared button (raise if missing), wire click event.
      def dispatch_button(raw_value, el)
        sym = parse_ident!(raw_value, "data-button")
        form = resolve_form_for(el)
        unless form.has_button?(sym)
          raise Lilac::Error,
                "data-button=#{sym.inspect} but form has no `f.button :#{sym}` declaration"
        end
        ref = wrap_ref(el)
        ref.on(:click) { |event| form.invoke_button(sym, event) }
      end

      # ---- helpers shared by dispatch_field / dispatch_button ----------

      # Validate + symbolize a bare identifier directive value
      # (data-field / data-button). `label` is used in the raise message.
      def parse_ident!(raw_value, label)
        name = raw_value.to_s.strip
        unless Grammar.method_ident?(name)
          raise Lilac::Error,
                "#{label}=#{raw_value.inspect}: expected a bare identifier"
        end
        name.to_sym
      end

      # Walk ancestors within the component subtree (stop at host root) to
      # find the nearest <form>. Returns the resolved Form, auto-creating
      # via host.form(name) if needed (form-spec §8). We don't ascend past
      # the host's own root so other components' form scopes are out of
      # reach by design.
      def resolve_form_for(el)
        node = el[:parentElement]
        host_root_js = @host.root.to_js
        loop do
          break if node.js_null?
          tag = node[:tagName]
          if !tag.js_null? && tag.to_s.downcase == "form"
            raw = node.call(:getAttribute, "data-form")
            sym = (raw.js_null? || raw.to_s.empty?) ? :default : raw.to_s.to_sym
            return @host.form(sym)
          end
          break if node == host_root_js
          node = node[:parentElement]
        end
        @host.form(:default)
      end

      # Find the first <input> / <textarea> / <select> within `el`
      # (inclusive). Returns the JS element or nil.
      def find_form_control(el)
        tag = el[:tagName].to_s.downcase
        return el if %w[input textarea select].include?(tag)
        %w[input textarea select].each do |selector|
          found = el.call(:querySelector, selector)
          return found unless found.js_null?
        end
        nil
      end

      # Auto-register field from HTML. type: checkbox → :checkbox, else
      # :text. initial: <input value="..."> attribute only (checked /
      # textContent / option selected are intentionally ignored, §10.3.1).
      def auto_register_field(form, sym, input_el)
        type = :text
        initial = ""
        if input_el && input_el[:tagName].to_s.downcase == "input"
          input_type = input_el.call(:getAttribute, "type")
          if !input_type.js_null? && input_type.to_s.downcase == "checkbox"
            type = :checkbox
            initial = false
          else
            val = input_el.call(:getAttribute, "value")
            initial = val.js_null? ? "" : val.to_s
          end
        end
        form.field(sym, initial: initial, type: type)
        Lilac.logger.warn(
          "auto-registered field :#{sym} (no `f.field :#{sym}` declaration) " \
          "in component #{@host.class.name}"
        )
      end
    end
  end
end
