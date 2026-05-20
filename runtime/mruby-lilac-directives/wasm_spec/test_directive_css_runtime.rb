Spec.describe "data-css-X (runtime scanner)" do
  Spec.assert "data-css-progress='@pct' sets `--progress` CSS variable on element" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="css-rt"><div data-css-progress="@pct">x</div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :pct
      define_method(:setup) { @pct = signal("25%") }
    end

    Lilac.register("css-rt", klass)
    Lilac.start
    Lilac.flush_async!

    target = body.call(:querySelector, "[data-component=\"css-rt\"] > div")
    Spec.assert_equal "25%", target[:style].call(:getPropertyValue, "--progress").to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"css-rt\"]"))
    inst.pct.value = "80%"
    Lilac.flush_async!
    Spec.assert_equal "80%", target[:style].call(:getPropertyValue, "--progress").to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-css-foo_bar (underscore) routes via logger.error (grammar)" do
    # Note: uppercase variants like `data-css-Progress` can't be
    # validated at runtime — browsers lowercase HTML attribute names
    # before the scanner sees them. CLI static lint still catches
    # those at build time. The runtime check fires for chars the
    # DOM preserves but our kebab grammar rejects: underscores,
    # leading digits, leading hyphens, etc.
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="css-bad-rt"><div data-css-foo_bar="@p">x</div></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @p = signal("0") }
    end

    Lilac.register("css-bad-rt", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error && entry[2].to_s.include?("data-css") }
    Spec.assert_equal 1, errors.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end
end
