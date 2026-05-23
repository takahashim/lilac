# data-tooltip="@msg" / data-tooltip="field_name" — reactive title-attribute
# binding. Mirrors the data-text shape but writes the `title` attribute
# instead of textContent. Inside data-each scopes, a bare identifier
# refers to a field of the current iteration item; outside iteration,
# bare identifiers silent-skip (matching data-text semantics).

module Lilac
  module Extras
    Lilac::Directives::Scanner.register_named_directive("tooltip", handler: self)

    def self.hook_tooltip(scanner, raw_value, el, item)
      value = Lilac::Directives::Value.parse(raw_value)
      unless value
        raise Lilac::Error,
              "Invalid value for data-tooltip: #{raw_value.inspect} " \
              "(expected `@ivar` or bare identifier)"
      end
      return if item.nil? && value.bare_ident?
      source = scanner.evaluator.bind_source(value, item)
      scanner.host.bind(scanner.wrap_ref(el), attr: { "title" => source })
    end
  end
end
