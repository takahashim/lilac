# data-autofocus — value-less flag directive. Calls element.focus()
# on mount (Scanner runs after the component's DOM subtree is in the
# live tree, so direct focus is safe).
#
# Equivalent to HTML's `autofocus` attribute, but framework-driven:
# component remounts (route changes, bind_list re-renders) re-fire the
# focus, where HTML's autofocus is honoured only at initial page load.
#
# `.focus()` on non-focusable elements is a browser no-op, so we don't
# constrain the tag set here.

module Lilac
  module Extras
    Lilac::Directives::Scanner.register_named_directive("autofocus", handler: self)

    def self.hook_autofocus(_scanner, _raw_value, el, _item)
      el.call(:focus)
    end
  end
end
