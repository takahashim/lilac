# data-autofocus — value-less flag directive. Calls element.focus()
# on mount (Scanner runs after the component's DOM subtree is in the
# live tree, so direct focus is safe).
#
# Equivalent to HTML's `autofocus` attribute, but framework-driven:
# component remounts (route changes, bind_list re-renders) re-fire the
# focus, where HTML's autofocus is honoured only at initial page load.
#
# Class-first Handler form (ADR-0027).

module Lilac
  module Extras
    class AutofocusDirective < Lilac::Directives::Handler
      attribute "data-autofocus"

      def wire(ctx)
        ctx.element.to_js.call(:focus)
      end
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Extras::AutofocusDirective")
