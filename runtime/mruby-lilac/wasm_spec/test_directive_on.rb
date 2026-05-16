Spec.describe "data-on-X directive (lilac-cli codegen target)" do
  Spec.assert "refs.lilN.on(:click) { |ev| m(ev) } wires click → method dispatch" do
    # Mirrors what lilac-cli's codegen produces for:
    #   <button data-ref="lilB" data-on-click="increment">+</button>
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><button data-ref="lilB">+</button></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :count
      define_method(:setup) { @count = signal(0) }
      define_method(:increment) { |_ev| @count.update(&:succ) }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        refs.lilB.on(:click) { |ev| increment(ev) }
      end
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    btn = body.call(:querySelector, "[data-ref=\"lilB\"]")
    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    Spec.assert_equal 0, inst.count.value

    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal 1, inst.count.value

    btn.call(:click)
    btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal 3, inst.count.value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "custom event name with hyphens routes via quoted symbol" do
    # Mirrors codegen for data-on-card-deleted="handle" → refs.lilB.on(:"card-deleted") {...}
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="lilB"></div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :received
      define_method(:setup) { @received = [] }
      define_method(:handle) { |ev| @received << ev[:detail][:id].to_i }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        refs.lilB.on(:"card-deleted") { |ev| handle(ev) }
      end
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.refs.lilB.dispatch("card-deleted", detail: { "id" => 42 })
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal [42], inst.received

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
