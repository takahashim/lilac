Spec.describe "data-bind (runtime scanner)" do
  Spec.assert "data-bind on text input wires two-way sync to @ivar Signal" do
    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="bind-text"><input data-bind="@name" type="text"></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :name
      define_method(:setup) { @name = signal("alice") }
    end

    Lilac.register("bind-text", klass)
    Lilac.start
    Lilac.flush_async!

    input = body.call(:querySelector, "input")
    # signal → DOM
    Spec.assert_equal "alice", input[:value].to_s

    inst = Lilac.find_for_element(
      body.call(:querySelector, "[data-component='bind-text']"))
    inst.name.value = "bob"
    Lilac.flush_async!
    Spec.assert_equal "bob", input[:value].to_s

    # DOM → signal
    ev = JS.global[:document][:defaultView][:Event]
    input[:value] = "carol"
    input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Lilac.flush_async!
    Spec.assert_equal "carol", inst.name.value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-bind on <input type=checkbox> binds :checked, not :value" do
    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="bind-cb"><input data-bind="@on" type="checkbox"></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :on
      define_method(:setup) { @on = signal(false) }
    end

    Lilac.register("bind-cb", klass)
    Lilac.start
    Lilac.flush_async!

    input = body.call(:querySelector, "input")
    Spec.assert_equal false, input[:checked].js_bool

    inst = Lilac.find_for_element(
      body.call(:querySelector, "[data-component='bind-cb']"))
    inst.on.value = true
    Lilac.flush_async!
    Spec.assert_equal true, input[:checked].js_bool

    ev = JS.global[:document][:defaultView][:Event]
    input[:checked] = false
    input.call(:dispatchEvent, ev.new("change", JS.object(bubbles: true)))
    Lilac.flush_async!
    Spec.assert_equal false, inst.on.value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-bind on <textarea> binds :value" do
    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="bind-ta"><textarea data-bind="@note"></textarea></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :note
      define_method(:setup) { @note = signal("hello") }
    end

    Lilac.register("bind-ta", klass)
    Lilac.start
    Lilac.flush_async!

    ta = body.call(:querySelector, "textarea")
    Spec.assert_equal "hello", ta[:value].to_s

    ev = JS.global[:document][:defaultView][:Event]
    ta[:value] = "world"
    ta.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Lilac.flush_async!
    inst = Lilac.find_for_element(
      body.call(:querySelector, "[data-component='bind-ta']"))
    Spec.assert_equal "world", inst.note.value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-bind with unparseable value routes via Lilac.logger.error" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    # `1bad` is not a valid identifier (digit prefix) → Value.parse fails.
    body[:innerHTML] =
      '<div data-component="bind-bad-literal"><input data-bind="1bad"></div>'

    klass = Class.new(Lilac::Component) { define_method(:setup) {} }
    Lilac.register("bind-bad-literal", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error }
    Spec.assert_true errors.length >= 1, "expected at least one error log entry"
    Spec.assert_true errors.first[2].to_s.include?("data-bind"),
                     "error mentions data-bind (#{errors.first[2].inspect})"

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end

  Spec.assert "data-bind pointing at Computed (not Signal) raises via logger" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="bind-bad-computed"><input data-bind="@upper"></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @raw   = signal("x")
        @upper = computed { @raw.value.upcase }
      end
    end
    Lilac.register("bind-bad-computed", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error }
    Spec.assert_true errors.length >= 1, "expected error for Computed bind"
    Spec.assert_true errors.first[2].to_s.include?("Signal"),
                     "error mentions Signal requirement (#{errors.first[2].inspect})"

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end

  Spec.assert "data-bind on non form-control element raises" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="bind-bad-tag"><div data-bind="@x"></div></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @x = signal("y") }
    end
    Lilac.register("bind-bad-tag", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error }
    Spec.assert_true errors.length >= 1, "expected error for <div> bind"

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end

  Spec.assert "data-bind + data-field on same element raises collision" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] =
      '<div data-component="bind-vs-field"><form>' \
      '<input data-bind="@x" data-field="x"></form></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @x = signal("")
        form { |_f| }
      end
    end
    Lilac.register("bind-vs-field", klass)
    Lilac.start
    Lilac.flush_async!

    errors = captured.select { |entry| entry[0] == :error }
    Spec.assert_true errors.length >= 1, "expected collision error"
    Spec.assert_true errors.first[2].to_s.include?("collision"),
                     "error mentions collision (#{errors.first[2].inspect})"

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    Lilac.flush_async!
  end
end
