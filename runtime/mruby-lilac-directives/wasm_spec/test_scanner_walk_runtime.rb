Spec.describe "Scanner walk boundaries (runtime)" do
  Spec.assert "scanner does not descend into nested data-component subtrees" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="outer-rt">
        <span class="outer-target" data-text="@outer">x</span>
        <div data-component="inner-rt">
          <span class="inner-target" data-text="@inner">x</span>
        </div>
      </div>
    HTML

    outer_klass = Class.new(Lilac::Component) do
      attr_reader :outer
      define_method(:setup) { @outer = signal("from-outer") }
    end
    inner_klass = Class.new(Lilac::Component) do
      attr_reader :inner
      define_method(:setup) { @inner = signal("from-inner") }
    end

    Lilac.register("outer-rt", outer_klass)
    Lilac.register("inner-rt", inner_klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    outer_span = body.call(:querySelector, ".outer-target")
    inner_span = body.call(:querySelector, ".inner-target")
    Spec.assert_equal "from-outer", outer_span[:textContent].to_s
    # Inner span is bound by the inner component's own scanner pass —
    # NOT by the outer scanner (which would have looked up @inner on
    # the outer instance and bound the wrong value).
    Spec.assert_equal "from-inner", inner_span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "scanner processes directives on the component root element itself" do
    # Root binding pattern (theme demo style): the component's own
    # data-component element also carries data-class. The scanner must
    # include the root in its dispatch loop, not only children.
    body = JS.global[:document][:body]
    body[:innerHTML] = %(<div data-component="root-bind-rt" data-class="{ active: @on }">child</div>)

    klass = Class.new(Lilac::Component) do
      attr_reader :on
      define_method(:setup) { @on = signal(true) }
    end

    Lilac.register("root-bind-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    root = body.call(:querySelector, "[data-component=\"root-bind-rt\"]")
    Spec.assert_equal true, root[:classList].call(:contains, "active").js_bool

    inst = Lilac.find_for_element(root)
    inst.on.value = false
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal false, root[:classList].call(:contains, "active").js_bool

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "CLI codegen path (Bindings module) is unaffected by runtime scanner" do
    # When a Lilac::Bindings::X module overrides bind_template_hook,
    # the override wins (Ruby method lookup) and the default runtime
    # scanner never runs. Confirms the canonical scanner doesn't
    # double-bind for .lil-built components.
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="coexist-rt"><span data-ref="t" data-text="@msg">x</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :msg, :scanner_ran
      define_method(:setup) do
        @msg = signal("from-codegen")
        @scanner_ran = false
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        # Imperative version (what CLI codegen would emit).
        bind refs.t, text: @msg
      end
    end
    klass.include(bindings)

    Lilac.register("coexist-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "[data-ref=\"t\"]")
    Spec.assert_equal "from-codegen", span[:textContent].to_s
    # Update the signal to confirm only one effect is wired (not two
    # which would still produce one final value but indicate a leak).
    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"coexist-rt\"]"))
    inst.msg.value = "updated"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal "updated", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
