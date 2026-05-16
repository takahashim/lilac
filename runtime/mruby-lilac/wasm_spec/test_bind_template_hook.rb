Spec.describe "Lilac::Component#bind_template_hook (directive codegen target)" do
  Spec.assert "default no-op: components without an override mount cleanly" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"></div>'
    klass = Class.new(Lilac::Component)
    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    root = body.call(:querySelector, "[data-component=\"C\"]")
    Spec.assert_true !Lilac.find_for_element(root).nil?
    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "user-defined bind_template_hook fires after setup" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"></div>'
    order = []
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { order << :setup }
      define_method(:bind_template_hook) { order << :bind_template_hook }
    end
    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal [:setup, :bind_template_hook], order
    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "bind_template_hook supplied via included module is invoked" do
    # Mirrors how lilac-cli's codegen wires generated bindings:
    # a separate `Lilac::Bindings::<ClassName>` module defines
    # `bind_template_hook` and is included into the user class.
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="label">orig</span></div>'
    klass = Class.new(Lilac::Component)
    mod = Module.new do
      define_method(:bind_template_hook) do
        refs.label.text = "patched"
      end
    end
    klass.include(mod)
    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    el = body.call(:querySelector, "[data-ref=\"label\"]")
    Spec.assert_equal "patched", el[:textContent].to_s
    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "errors inside bind_template_hook are routed through the logger, not the mount path" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"></div>'
    klass = Class.new(Lilac::Component) do
      define_method(:bind_template_hook) { raise "boom from bind_template_hook" }
    end
    Lilac.register("C", klass)
    # Should NOT raise out of Lilac.start — the begin/rescue inside
    # mount routes the exception through Lilac.logger.error.
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    root = body.call(:querySelector, "[data-component=\"C\"]")
    # Component is still mounted; only the hook errored.
    Spec.assert_true !Lilac.find_for_element(root).nil?
    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
