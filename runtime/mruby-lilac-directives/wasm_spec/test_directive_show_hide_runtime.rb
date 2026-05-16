Spec.describe "data-show / data-hide (runtime scanner)" do
  Spec.assert "data-show='@visible' toggles `lil-hidden` class inversely to signal truthiness" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="show-rt"><span data-show="@visible">target</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :visible
      define_method(:setup) { @visible = signal(true) }
    end

    Lilac.register("show-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "span")
    Spec.assert_equal false, span[:classList].call(:contains, "lil-hidden").js_bool

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"show-rt\"]"))
    inst.visible.value = false
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal true, span[:classList].call(:contains, "lil-hidden").js_bool

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-hide='@hidden' toggles `lil-hidden` class with signal truthiness" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="hide-rt"><span data-hide="@hidden">target</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :hidden
      define_method(:setup) { @hidden = signal(false) }
    end

    Lilac.register("hide-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "span")
    Spec.assert_equal false, span[:classList].call(:contains, "lil-hidden").js_bool

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"hide-rt\"]"))
    inst.hidden.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal true, span[:classList].call(:contains, "lil-hidden").js_bool

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-show + data-hide on same element raises (correctness)" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="conflict-rt"><span data-show="@a" data-hide="@b">x</span></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @a = signal(true); @b = signal(false) }
    end

    Lilac.register("conflict-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    errors = captured.select { |entry| entry[0] == :error && entry[2].to_s.include?("collision") }
    Spec.assert_equal 1, errors.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
