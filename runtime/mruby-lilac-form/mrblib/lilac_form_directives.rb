# Three class-based directive handlers for the form gem (ADR-0027).
# Each is a thin shell that delegates into `Lilac::Form::Wiring` module
# functions (defined in `lilac_form_wiring.rb`), passing the Context
# through unchanged. Wiring helpers take `ctx` and reach for `ctx.host`
# / `ctx.element` / `ctx.wrap(...)` — no scanner-internal access.

module Lilac
  class Form
    class FormDirective < Lilac::Directives::Handler
      attribute "data-form"
      phase :pre

      def wire(ctx)
        Wiring.validate_data_form_target!(ctx)
      end
    end

    class FieldDirective < Lilac::Directives::Handler
      attribute "data-field"
      phase :pre

      def wire(ctx)
        Wiring.dispatch_field(ctx)
      end
    end

    class ButtonDirective < Lilac::Directives::Handler
      attribute "data-button"
      phase :pre

      def wire(ctx)
        Wiring.dispatch_button(ctx)
      end
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Form::FormDirective")
Lilac::Directives::Scanner.register("Lilac::Form::FieldDirective")
Lilac::Directives::Scanner.register("Lilac::Form::ButtonDirective")
