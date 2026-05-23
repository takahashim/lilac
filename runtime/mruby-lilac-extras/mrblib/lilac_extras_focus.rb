# data-autofocus — value-less flag directive. Calls element.focus()
# on mount (Scanner runs after the component's DOM subtree is in the
# live tree, so direct focus is safe).
#
# Equivalent to HTML's `autofocus` attribute, but framework-driven:
# component remounts (route changes, bind_list re-renders) re-fire the
# focus, where HTML's autofocus is honoured only at initial page load.

Lilac::Directives::Scanner.register_directive(
  pattern: /\Adata-autofocus\z/, kind: :autofocus
) do |_scanner, _name, _raw_value, el, _item, _descriptor|
  el.call(:focus)
end
