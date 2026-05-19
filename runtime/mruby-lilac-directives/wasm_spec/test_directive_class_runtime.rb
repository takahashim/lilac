Spec.describe "data-class (runtime scanner)" do
  Spec.assert "data-class with multiple keys toggles classes reactively" do
    body = JS.global[:document][:body]
    body[:innerHTML] = %(<div data-component="cls-rt"><span data-class="{ active: @on, 'btn-primary': @primary }">x</span></div>)

    klass = Class.new(Lilac::Component) do
      attr_reader :on, :primary
      define_method(:setup) do
        @on = signal(true)
        @primary = signal(false)
      end
    end

    Lilac.register("cls-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "span")
    Spec.assert_equal true, span[:classList].call(:contains, "active").js_bool
    Spec.assert_equal false, span[:classList].call(:contains, "btn-primary").js_bool

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"cls-rt\"]"))
    inst.on.value = false
    inst.primary.value = true
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal false, span[:classList].call(:contains, "active").js_bool
    Spec.assert_equal true, span[:classList].call(:contains, "btn-primary").js_bool

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-class with double-quoted Tailwind-style key (contains `:`)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = %(<div data-component="cls-tw-rt"><span data-class='{ "hover:bg-blue": @hov }'>x</span></div>)

    klass = Class.new(Lilac::Component) do
      attr_reader :hov
      define_method(:setup) { @hov = signal(true) }
    end

    Lilac.register("cls-tw-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "span")
    Spec.assert_equal true, span[:classList].call(:contains, "hover:bg-blue").js_bool

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-class containing reserved `lil-hidden` key raises (correctness)" do
    captured = []
    prev_logger = Lilac.logger
    Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

    body = JS.global[:document][:body]
    body[:innerHTML] = %(<div data-component="cls-bad-rt"><span data-class="{ 'lil-hidden': @h }">x</span></div>)

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @h = signal(true) }
    end

    Lilac.register("cls-bad-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    errors = captured.select { |entry| entry[0] == :error && entry[2].to_s.include?("lil-hidden") }
    Spec.assert_equal 1, errors.length

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.logger = prev_logger
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "ClassParser smoke (bare and quoted keys + values)" do
    pairs = Lilac::Directives::ClassParser.parse("{ active: @on, 'btn-primary': @p, \"x:y\": flagged }")
    Spec.assert_equal 3, pairs.length
    Spec.assert_equal ["active", "@on"], pairs[0]
    Spec.assert_equal ["btn-primary", "@p"], pairs[1]
    Spec.assert_equal ["x:y", "flagged"], pairs[2]
  end
end
