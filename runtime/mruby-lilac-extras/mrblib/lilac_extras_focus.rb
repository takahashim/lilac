# data-autofocus — value-less flag directive. Calls element.focus()
# on mount (Scanner runs after the component's DOM subtree is in the
# live tree, so direct focus is safe).
#
# Equivalent to HTML's `autofocus` attribute, but framework-driven:
# component remounts (route changes, bind_list re-renders) re-fire the
# focus, where HTML's autofocus is honoured only at initial page load.

module Lilac
  module Extras
    Lilac::Directives::Scanner.register_named_directive(
      "autofocus", handler: self, value: :none,
      allowed_tags: %w[input textarea select button]
    )

    def self.hook_autofocus(_scanner, _raw_value, el, _item)
      el.call(:focus)
    end
  end
end
