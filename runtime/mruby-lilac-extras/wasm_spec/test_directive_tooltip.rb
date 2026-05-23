Spec.describe "data-tooltip (runtime scanner)" do
  Spec.assert "data-tooltip='@msg' wires reactive title attribute" do
    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="tip-rt"><span data-tooltip="@msg">hover</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end

    Lilac.register("tip-rt", klass)
    Lilac.start
    Lilac.flush_async!

    span = body.call(:querySelector, "span")
    Spec.assert_equal "hello", span.call(:getAttribute, "title").to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"tip-rt\"]"))
    inst.msg.value = "world"
    Lilac.flush_async!
    Spec.assert_equal "world", span.call(:getAttribute, "title").to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-tooltip with invalid value raises via logger.error" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="tip-bad"><span data-tooltip="@bad.value">x</span></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @bad = signal("ignored") }
    end

    Lilac.register("tip-bad", klass)
    Lilac.start
    Lilac.flush_async!

    err = captured.find { |level, _, _| level == :error }
    Spec.assert_true err, "expected logger.error for invalid value"
    Spec.assert_true err[2].to_s.include?("data-tooltip"), "expected error msg to mention data-tooltip"

    Lilac.logger = prev_logger
    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
