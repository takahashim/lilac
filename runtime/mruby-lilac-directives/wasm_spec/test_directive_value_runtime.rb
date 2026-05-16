Spec.describe "data-value (runtime scanner)" do
  Spec.assert "data-value='@title' wires two-way binding to <input>" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="value-rt"><input data-value="@title" /></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :title
      define_method(:setup) { @title = signal("hello") }
    end

    Lilac.register("value-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    input = body.call(:querySelector, "input")
    Spec.assert_equal "hello", input[:value].to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"value-rt\"]"))
    inst.title.value = "world"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "world", input[:value].to_s

    input[:value] = "from-dom"
    input.dispatch("input", bubbles: true)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "from-dom", inst.title.value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-value on <div> warns and skips (ergonomics)" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, _err) { captured << [level, msg.to_s] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="value-bad-rt"><div data-value="@title">x</div></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @title = signal("x") }
    end

    Lilac.register("value-bad-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    warns = captured.select { |entry| entry[0] == :warn && entry[1].include?("data-value") }
    Spec.assert_equal 1, warns.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-value with it.path routes via logger.error (writable required)" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="value-itp-rt"><input data-value="it.x" /></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) {}
    end

    Lilac.register("value-itp-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    errors = captured.select { |entry| entry[0] == :error && entry[2].to_s.include?("data-value") }
    Spec.assert_equal 1, errors.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
