Spec.describe "data-attr-X (runtime scanner)" do
  Spec.assert "data-attr-aria-label='@label' wires reactive attribute" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="attr-rt"><button data-attr-aria-label="@label">x</button></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :label
      define_method(:setup) { @label = signal("close") }
    end

    Lilac.register("attr-rt", klass)
    Lilac.start
    Lilac.flush_async!

    btn = body.call(:querySelector, "button")
    Spec.assert_equal "close", btn.call(:getAttribute, "aria-label").to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"attr-rt\"]"))
    inst.label.value = "dismiss"
    Lilac.flush_async!
    Spec.assert_equal "dismiss", btn.call(:getAttribute, "aria-label").to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-attr-onclick (banned) raises via logger.error" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="ban-rt"><button data-attr-onclick="@x">x</button></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @x = signal("alert(1)") }
    end

    Lilac.register("ban-rt", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error && entry[2].to_s.include?("banned") }
    Spec.assert_equal 1, errors.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end
end
