# Wire form-related Scanner extensions. Registers data-form /
# data-field / data-button directive dispatch, the <form> element's
# submit auto-wire, and collection-phase validations (second plain
# <form>, <input form="...">). All implementations live in
# `Lilac::Form::Wiring` (see `lilac_form_wiring.rb`).

module Lilac
  class Form
    Wiring # ensure constant load (no-op if already defined)
  end
end

Lilac::Directives::Scanner.register_collect_hook do |scanner, tag, attrs, descriptor|
  Lilac::Form::Wiring.validate_form_element!(scanner, tag, attrs, descriptor)
  Lilac::Form::Wiring.warn_on_form_attr(scanner, tag, attrs)
end

Lilac::Directives::Scanner.register_tag_hook("form", phase: :pre) do |scanner, el, attrs, _descriptor|
  Lilac::Form::Wiring.wire_form_submit(scanner, el, attrs)
end

Lilac::Directives::Scanner.register_directive(
  pattern: /\Adata-form\z/, kind: :form, phase: :pre
) do |_scanner, _name, _raw_value, el, _item, descriptor|
  Lilac::Form::Wiring.validate_data_form_target!(el, descriptor)
end

Lilac::Directives::Scanner.register_directive(
  pattern: /\Adata-field\z/, kind: :field, phase: :pre
) do |scanner, _name, raw_value, el, _item, _descriptor|
  Lilac::Form::Wiring.dispatch_field(scanner, raw_value, el)
end

Lilac::Directives::Scanner.register_directive(
  pattern: /\Adata-button\z/, kind: :button, phase: :pre
) do |scanner, _name, raw_value, el, _item, _descriptor|
  Lilac::Form::Wiring.dispatch_button(scanner, raw_value, el)
end
