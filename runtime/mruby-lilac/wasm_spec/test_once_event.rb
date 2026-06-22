Spec.describe "RefElement#once" do
  Spec.assert "resolves with the event the first time it fires" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="once-ok"><div data-ref="box"></div></div>'
    klass = Class.new(Lilac::Component) { define_method(:setup) {} }
    Lilac.register("once-ok", klass)
    Lilac.start
    Lilac.flush_async!

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"once-ok\"]"))
    box_js = body.call(:querySelector, "[data-component=\"once-ok\"] [data-ref=\"box\"]")

    # Fire the event after `.await` suspends the fiber. The listener is
    # registered synchronously inside `once` (Promise executor runs at
    # construction), so it is already in place when the timer fires.
    JS.global.call(:setTimeout, JS.callback {
      ev = Lilac.__window__[:CustomEvent].new("ping", JS.object(detail: 42))
      box_js.call(:dispatchEvent, ev)
    }, 0)

    event = inst.refs.box.once(:ping).await
    Spec.assert_equal 42, event[:detail].to_i

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "rejects when an error event fires first" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="once-err"><div data-ref="box"></div></div>'
    klass = Class.new(Lilac::Component) { define_method(:setup) {} }
    Lilac.register("once-err", klass)
    Lilac.start
    Lilac.flush_async!

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"once-err\"]"))
    box_js = body.call(:querySelector, "[data-component=\"once-err\"] [data-ref=\"box\"]")

    JS.global.call(:setTimeout, JS.callback {
      box_js.call(:dispatchEvent, Lilac.__window__[:CustomEvent].new("boom", JS.object))
    }, 0)

    raised = false
    begin
      inst.refs.box.once(:load, error: :boom).await
    rescue JS::Error
      raised = true
    end
    Spec.assert_equal true, raised

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "removes the losing listener after settling (no second fire)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="once-clean"><div data-ref="box"></div></div>'
    klass = Class.new(Lilac::Component) { define_method(:setup) {} }
    Lilac.register("once-clean", klass)
    Lilac.start
    Lilac.flush_async!

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"once-clean\"]"))
    box_js = body.call(:querySelector, "[data-component=\"once-clean\"] [data-ref=\"box\"]")

    JS.global.call(:setTimeout, JS.callback {
      box_js.call(:dispatchEvent, Lilac.__window__[:CustomEvent].new("done", JS.object))
    }, 0)
    inst.refs.box.once(:done, error: :fail).await

    # The `:fail` (error) listener must have been torn down on settle —
    # dispatching it now must not reject anything or raise.
    box_js.call(:dispatchEvent, Lilac.__window__[:CustomEvent].new("fail", JS.object))
    Lilac.flush_async!
    Spec.assert_equal true, true

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
