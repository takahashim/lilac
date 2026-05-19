Spec.describe "data-text / data-unsafe-html (runtime scanner)" do
  Spec.assert "data-text='@msg' wires text binding from declarative attribute alone" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="text-rt"><span data-text="@msg">initial</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end

    Lilac.register("text-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "span")
    Spec.assert_equal "hello", span[:textContent].to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"text-rt\"]"))
    inst.msg.value = "world"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "world", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-unsafe-html='@html' wires innerHTML binding" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="html-rt"><div data-unsafe-html="@body"></div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :body
      define_method(:setup) { @body = signal("<em>plain</em>") }
    end

    Lilac.register("html-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    inner = body.call(:querySelector, "[data-component=\"html-rt\"] > div")
    Spec.assert_equal "<em>plain</em>", inner[:innerHTML].to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"html-rt\"]"))
    inst.body.value = "<strong>bold</strong>"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "<strong>bold</strong>", inner[:innerHTML].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "invalid value (not @ivar / bare ident) routes via Lilac.logger.error" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    # `1bad` starts with digit → not a valid identifier, fails Value.parse.
    body[:innerHTML] = '<div data-component="bad-rt"><span data-text="1bad">x</span></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) {}
    end

    Lilac.register("bad-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    errors = captured.select { |entry| entry[0] == :error }
    Spec.assert_equal 1, errors.length
    Spec.assert_true errors.first[2].to_s.include?("data-text"), "error message mentions data-text (#{errors.first[2].inspect})"

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
