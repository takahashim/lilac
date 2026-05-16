Spec.describe "data-checked (runtime scanner)" do
  Spec.assert "data-checked='@on' wires two-way binding to <input type=checkbox>" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="chk-rt"><input type="checkbox" data-checked="@on" /></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :on
      define_method(:setup) { @on = signal(false) }
    end

    Lilac.register("chk-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    input = body.call(:querySelector, "input")
    Spec.assert_equal false, input[:checked].js_bool

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"chk-rt\"]"))
    inst.on.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal true, input[:checked].js_bool

    input[:checked] = false
    input.dispatch("change", bubbles: true)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal false, inst.on.value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-checked on <input type=text> warns and skips" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, _err) { captured << [level, msg.to_s] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="chk-bad-rt"><input type="text" data-checked="@on" /></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @on = signal(false) }
    end

    Lilac.register("chk-bad-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    warns = captured.select { |entry| entry[0] == :warn && entry[1].include?("data-checked") }
    Spec.assert_equal 1, warns.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
