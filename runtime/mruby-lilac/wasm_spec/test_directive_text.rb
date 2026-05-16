Spec.describe "data-text directive (lilac-cli codegen target)" do
  Spec.assert "bind refs.llcN, text: @signal mirrors signal updates into textContent" do
    # Mirrors what lilac-cli's codegen produces for:
    #   <span data-ref="llcT" data-text="@msg"></span>
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="llcT">initial</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.llcT, text: @msg }
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "[data-ref=\"llcT\"]")
    Spec.assert_equal "hello", span[:textContent].to_s

    root = body.call(:querySelector, "[data-component=\"C\"]")
    inst = Lilac.find_for_element(root)
    inst.msg.value = "world"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "world", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "bind refs.llcN, text: @computed reacts to dependency changes" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="llcT">0</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :count
      define_method(:setup) do
        @count = signal(0)
        @label = computed { "Count: #{@count.value}" }
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.llcT, text: @label }
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "[data-ref=\"llcT\"]")
    Spec.assert_equal "Count: 0", span[:textContent].to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.count.update { |n| n + 5 }
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "Count: 5", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
