Spec.describe "data-show / data-hide directives (lil-hidden class toggle)" do
  Spec.assert "data-show: lil-hidden present when signal is falsy, absent when truthy" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gS">payload</div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :visible
      define_method(:setup) { @visible = signal(true) }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind refs.gS, class: { "lil-hidden" => computed { !@visible.value } }
      end
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    target = body.call(:querySelector, "[data-ref=\"gS\"]")
    has = ->() { target[:classList].call(:contains, "lil-hidden").js_bool }

    Spec.assert_false has.call

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.visible.value = false
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true has.call

    inst.visible.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_false has.call

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-hide: lil-hidden present when signal is truthy, absent when falsy" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gH">payload</div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :loading
      define_method(:setup) { @loading = signal(false) }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind refs.gH, class: { "lil-hidden" => computed { @loading.value } }
      end
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    target = body.call(:querySelector, "[data-ref=\"gH\"]")
    has = ->() { target[:classList].call(:contains, "lil-hidden").js_bool }

    Spec.assert_false has.call

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.loading.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_true has.call

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
