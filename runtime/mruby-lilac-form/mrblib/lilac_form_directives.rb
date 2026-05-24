# Three class-based directive handlers for the form gem (ADR-0027).
# Each is a thin shell that delegates into `Lilac::Form::Wiring` module
# functions (defined in `lilac_form_wiring.rb`), which still take the
# scanner + raw element so they can be reused by both runtime paths
# (mrblib lilac-full eval and the CLI's hand-tuned emit).
#
# Form is a Lilac-internal gem; the `ctx.advanced.scanner` escape hatch
# is intentionally used here so Wiring's existing battle-tested helpers
# don't have to be ported to a Context-only signature. Third-party
# packages should not rely on `ctx.advanced` (see ADR-0027 §27.5).

module Lilac
  class Form
    class FormDirective < Lilac::Directives::Handler
      attribute "data-form"
      phase :pre

      def wire(ctx)
        Wiring.validate_data_form_target!(ctx.element.to_js, ctx.descriptor)
      end
    end

    class FieldDirective < Lilac::Directives::Handler
      attribute "data-field"
      phase :pre

      def wire(ctx)
        Wiring.dispatch_field(ctx.advanced.scanner, ctx.raw_value, ctx.element.to_js)
      end
    end

    class ButtonDirective < Lilac::Directives::Handler
      attribute "data-button"
      phase :pre

      def wire(ctx)
        Wiring.dispatch_button(ctx.advanced.scanner, ctx.raw_value, ctx.element.to_js)
      end
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Form::FormDirective")
Lilac::Directives::Scanner.register("Lilac::Form::FieldDirective")
Lilac::Directives::Scanner.register("Lilac::Form::ButtonDirective")
