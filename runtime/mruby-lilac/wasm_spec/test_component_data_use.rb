# data-use= expansion (ADR-0029). A `<div data-use="X">` placeholder is
# filled at `Lilac.start` from the matching `<template>`'s
# `<div data-component="X">` definition, then mounted via the normal
# component path. Pins the runtime contract that the build pipeline +
# parity-runner rely on:
#   - the use element keeps `data-use=` and gains `data-component-id=`
#   - the definition's inner markup is injected (children, not the
#     `data-component=` wrapper — that wrapper never materializes live)
#   - directives inside the injected markup bind reactively
Spec.describe "data-use= expansion (ADR-0029)" do
  Spec.after { Lilac.reset! }

  def seed_use_page
    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-use="use-demo"></div>' \
      '<template><div data-component="use-demo">' \
      '<span class="t" data-text="@msg">init</span>' \
      '</div></template>'
    body
  end

  Spec.assert "use element is expanded, mounted, and renders the signal" do
    body = seed_use_page

    klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    Lilac.register("use-demo", klass)

    Lilac.start
    Lilac.flush_async!

    use_el = body.call(:querySelector, "[data-use=\"use-demo\"]")
    # The use element is the mounted component: keeps data-use, gains id.
    Spec.assert_false use_el.call(:getAttribute, "data-component-id").js_null?
    inst = Lilac.find_for_element(use_el)
    Spec.assert_true inst.is_a?(klass)

    # Definition markup was injected (children hoisted into the use el);
    # the data-component= wrapper itself never appears in the live DOM.
    Spec.assert_true body.call(:querySelector, "[data-component=\"use-demo\"]").js_null?
    span = body.call(:querySelector, ".t")
    Spec.assert_false span.js_null?
    Spec.assert_equal "hello", span[:textContent].to_s

    # Reactivity through the injected directive.
    inst.msg.value = "world"
    Lilac.flush_async!
    Spec.assert_equal "world", span[:textContent].to_s

    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "pre-filled use element is not overwritten by the definition" do
    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-use="use-demo"><span class="t">kept</span></div>' \
      '<template><div data-component="use-demo">' \
      '<span class="t" data-text="@msg">init</span>' \
      '</div></template>'

    klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    Lilac.register("use-demo", klass)

    Lilac.start
    Lilac.flush_async!

    # Existing content wins (empty-check guard), so no @msg binding ran.
    span = body.call(:querySelector, ".t")
    Spec.assert_equal "kept", span[:textContent].to_s

    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "unknown data-use name is left unmounted" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-use="no-such-component"></div>'

    Lilac.start
    Lilac.flush_async!

    use_el = body.call(:querySelector, "[data-use=\"no-such-component\"]")
    Spec.assert_true use_el.call(:getAttribute, "data-component-id").js_null?
    Spec.assert_true Lilac.find_for_element(use_el).nil?

    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
