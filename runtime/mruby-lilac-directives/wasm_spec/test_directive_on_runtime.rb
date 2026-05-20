Spec.describe "data-on-X (runtime scanner)" do
  Spec.assert "data-on-click='increment' wires click → method dispatch" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="on-rt"><button data-on-click="increment">+</button></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :count
      define_method(:setup) { @count = signal(0) }
      define_method(:increment) { |_ev| @count.update(&:succ) }
    end

    Lilac.register("on-rt", klass)
    Lilac.start
    Lilac.flush_async!

    btn = body.call(:querySelector, "button")
    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"on-rt\"]"))
    Spec.assert_equal 0, inst.count.value

    btn.call(:click)
    Lilac.flush_async!
    Spec.assert_equal 1, inst.count.value

    btn.call(:click)
    btn.call(:click)
    Lilac.flush_async!
    Spec.assert_equal 3, inst.count.value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-on-card-deleted='handle' routes hyphenated custom event" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="evt-rt"><div data-ref="emitter" data-on-card-deleted="handle"></div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :received
      define_method(:setup) { @received = [] }
      define_method(:handle) { |ev| @received << ev[:detail][:id].to_i }
    end

    Lilac.register("evt-rt", klass)
    Lilac.start
    Lilac.flush_async!

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"evt-rt\"]"))
    inst.refs.emitter.dispatch("card-deleted", detail: { "id" => 42 })
    Lilac.flush_async!
    Spec.assert_equal [42], inst.received

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-on-click with non-ident value (e.g. `save?`) routes via logger.error" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="on-bad-rt"><button data-on-click="save?">x</button></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) {}
    end

    Lilac.register("on-bad-rt", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error && entry[2].to_s.include?("data-on-click") }
    Spec.assert_equal 1, errors.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end
end
