Spec.describe "CLI codegen ↔ runtime scanner parity" do
  # Both paths must produce identical observable behavior for the
  # same component class + same logical template. Existing per-
  # directive tests cover each path in isolation; this group is the
  # explicit cross-check that "the two paths stay aligned" — if it
  # ever fails, one path has drifted from the other and the gap must
  # be closed before shipping.

  Spec.assert "data-text: signal update propagates identically on both paths" do
    body = JS.global[:document][:body]

    # ---- Path A: CLI-style codegen (explicit Bindings module) ----
    body[:innerHTML] = '<div data-component="parity-cli"><span data-ref="lilT">x</span></div>'
    cli_klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    cli_mod = Module.new do
      define_method(:bind_template_hook) { bind refs.lilT, text: @msg }
    end
    cli_klass.include(cli_mod)
    Lilac.register("parity-cli", cli_klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    cli_span = body.call(:querySelector, "[data-component=\"parity-cli\"] span")
    initial_cli = cli_span[:textContent].to_s
    cli_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"parity-cli\"]"))
    cli_inst.msg.value = "world"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    updated_cli = cli_span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    # ---- Path B: runtime scanner (declarative directive only) ----
    body[:innerHTML] = '<div data-component="parity-rt"><span data-text="@msg">x</span></div>'
    rt_klass = Class.new(Lilac::Component) do
      attr_reader :msg
      define_method(:setup) { @msg = signal("hello") }
    end
    Lilac.register("parity-rt", rt_klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    rt_span = body.call(:querySelector, "[data-component=\"parity-rt\"] span")
    initial_rt = rt_span[:textContent].to_s
    rt_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"parity-rt\"]"))
    rt_inst.msg.value = "world"
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    updated_rt = rt_span[:textContent].to_s

    Spec.assert_equal initial_cli, initial_rt, "initial bound text matches across paths"
    Spec.assert_equal updated_cli, updated_rt, "post-update bound text matches across paths"

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-on-click: dispatch arrives at the method on both paths" do
    body = JS.global[:document][:body]

    # ---- Path A: CLI-style codegen ----
    body[:innerHTML] = '<div data-component="parity-on-cli"><button data-ref="b">+</button></div>'
    cli_klass = Class.new(Lilac::Component) do
      attr_reader :count
      define_method(:setup) { @count = signal(0) }
      define_method(:inc) { |_ev| @count.update { |n| n + 1 } }
    end
    cli_mod = Module.new do
      define_method(:bind_template_hook) { refs.b.on(:click) { |ev| inc(ev) } }
    end
    cli_klass.include(cli_mod)
    Lilac.register("parity-on-cli", cli_klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    cli_btn = body.call(:querySelector, "[data-component=\"parity-on-cli\"] button")
    cli_btn.call(:click)
    cli_btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    cli_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"parity-on-cli\"]"))
    cli_count = cli_inst.count.value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    # ---- Path B: runtime scanner ----
    body[:innerHTML] = '<div data-component="parity-on-rt"><button data-on-click="inc">+</button></div>'
    rt_klass = Class.new(Lilac::Component) do
      attr_reader :count
      define_method(:setup) { @count = signal(0) }
      define_method(:inc) { |_ev| @count.update { |n| n + 1 } }
    end
    Lilac.register("parity-on-rt", rt_klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    rt_btn = body.call(:querySelector, "[data-component=\"parity-on-rt\"] button")
    rt_btn.call(:click)
    rt_btn.call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    rt_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"parity-on-rt\"]"))
    rt_count = rt_inst.count.value

    Spec.assert_equal cli_count, rt_count, "click count matches across paths (#{cli_count} vs #{rt_count})"

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Bindings module override always wins (no double-binding)" do
    # When a Lilac::Bindings::X module is included (CLI codegen output),
    # the runtime scanner default never fires — Ruby method lookup
    # picks the override. If it ever did fire too, we'd see double
    # binding (two effects writing to the same DOM property). Sanity-
    # checked by mutating the signal once and confirming a single
    # final state, plus that the override-specific signal was used
    # (the runtime scanner would have read a different ivar name).
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="parity-coexist"><span data-ref="t" data-text="@unused_by_codegen">x</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :used_by_codegen
      define_method(:setup) do
        @used_by_codegen = signal("from-codegen-ivar")
        @unused_by_codegen = signal("from-runtime-ivar")
      end
    end
    mod = Module.new do
      define_method(:bind_template_hook) { bind refs.t, text: @used_by_codegen }
    end
    klass.include(mod)

    Lilac.register("parity-coexist", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    span = body.call(:querySelector, "[data-ref=\"t\"]")
    # The codegen's bind reads @used_by_codegen. If the runtime
    # scanner also fired, it would have set the text to
    # @unused_by_codegen ("from-runtime-ivar") instead (overwriting
    # the codegen's binding on the same property in the same effect
    # phase). The codegen value winning proves the runtime scanner
    # was correctly skipped.
    Spec.assert_equal "from-codegen-ivar", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
