# data-tooltip="@msg" / data-tooltip="field_name" — reactive title-attribute
# binding. Mirrors the data-text shape but writes the `title` attribute
# instead of textContent. Inside data-each scopes, a bare identifier
# refers to a field of the current iteration item; outside iteration,
# bare identifiers silent-skip (matching data-text semantics).
#
# Class-first Handler form (ADR-0027). Registration is by class-name
# String so the `Lilac::Directives::Scanner.register` call works
# regardless of which file is loaded first.

module Lilac
  module Extras
    class TooltipDirective < Lilac::Directives::Handler
      attribute "data-tooltip"

      def wire(ctx)
        v = ctx.value
        unless v.is_a?(Lilac::Directives::Value)
          raise Lilac::Error,
                "Invalid value for data-tooltip: #{ctx.raw_value.inspect} " \
                "(expected `@ivar` or bare identifier)"
        end
        ctx.bind_attribute("title", to: v)
      end
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Extras::TooltipDirective")
