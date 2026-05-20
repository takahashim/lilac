Spec.describe "data-text directive (lilac-cli codegen target)" do
  Spec.assert "bind refs.lilN, text: @signal mirrors signal updates into textContent" do
    # Mirrors what lilac-cli's codegen produces for:
    #   <span data-ref="lilT" data-text="@msg"></span>
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="lilT">initial</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.lilT, text: @msg }
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    Lilac.flush_async!

    span = body.call(:querySelector, "[data-ref=\"lilT\"]")
    Spec.assert_equal "hello", span[:textContent].to_s

    root = body.call(:querySelector, "[data-component=\"C\"]")
    inst = Lilac.find_for_element(root)
    inst.msg.value = "world"
    Lilac.flush_async!
    Spec.assert_equal "world", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "bind refs.lilN, text: @computed reacts to dependency changes" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><span data-ref="lilT">0</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :count
      define_method(:setup) do
        @count = signal(0)
        @label = computed { "Count: #{@count.value}" }
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.lilT, text: @label }
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    Lilac.flush_async!

    span = body.call(:querySelector, "[data-ref=\"lilT\"]")
    Spec.assert_equal "Count: 0", span[:textContent].to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.count.update { |n| n + 5 }
    Lilac.flush_async!
    Spec.assert_equal "Count: 5", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
