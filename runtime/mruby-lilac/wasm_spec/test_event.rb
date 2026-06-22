Spec.describe "Lilac::Event wrapper" do
  Spec.after { Lilac.reset! }

  Spec.assert "on handler receives a Lilac::Event with ergonomic accessors" do
    doc = JS.global[:document]
    doc[:body][:innerHTML] =
      '<div data-component="ev-basic"><div class="player"><button data-ref="btn">x</button></div></div>'
    seen = {}
    # Capture primitives *inside* the handler, where the event is live —
    # storing JS handles (event.target) and reading them after dispatch
    # is fragile across DOM engines.
    k = Class.new(Lilac::Component) do
      define_method(:setup) do
        refs.btn.on(:probe) do |event|
          seen[:class]          = event.class
          seen[:type]           = event.type
          seen[:target_is_ref]  = Lilac::RefElement === event.target
          seen[:target_tag]     = event.target.js[:tagName].to_s
          seen[:closest_player] = !event.target.closest(".player").nil?
          seen[:raw_tag]        = event[:target][:tagName].to_s   # bracket = raw JS
        end
      end
    end
    Lilac.register "ev-basic", k
    Lilac.start

    # Dispatch a CustomEvent on the button via RefElement#dispatch:
    # dispatchEvent sets `event.target` to the button reliably across
    # DOM engines (the synthetic `.click()` helper doesn't, and a bare
    # `new Event(...)` populates target inconsistently host-to-host).
    inst = Lilac.find_for_element(doc.call(:querySelector, "[data-component='ev-basic']"))
    inst.refs.btn.dispatch(:probe)

    Spec.assert_true Lilac::Event == seen[:class]
    Spec.assert_equal "probe", seen[:type]
    Spec.assert_true seen[:target_is_ref]            # event.target → RefElement
    Spec.assert_equal "BUTTON", seen[:target_tag]
    Spec.assert_true seen[:closest_player]           # target.closest reaches .player
    Spec.assert_equal "BUTTON", seen[:raw_tag]       # bracket stays raw JS
  end

  Spec.assert "prevent_default / call / key behave correctly" do
    doc = JS.global[:document]
    win = Lilac.__window__
    doc[:body][:innerHTML] = '<div data-component="ev-key"></div>'
    seen = {}
    k = Class.new(Lilac::Component) do
      define_method(:setup) do
        document.on(:keydown) do |event|
          seen[:key] = event.key
          event.prevent_default
          seen[:prevented] = event.default_prevented?
        end
      end
    end
    Lilac.register "ev-key", k
    Lilac.start

    ev = win[:KeyboardEvent].new("keydown", JS.object(key: "ArrowRight", cancelable: true))
    doc.call(:dispatchEvent, ev)

    Spec.assert_equal "ArrowRight", seen[:key]
    Spec.assert_true seen[:prevented]
    # explicit call still works as the raw escape hatch
    Spec.assert_true ev[:defaultPrevented].js_bool
  end

  Spec.assert "key is nil for non-keyboard events; [:detail] reads raw" do
    doc = JS.global[:document]
    doc[:body][:innerHTML] = '<div data-component="ev-detail" data-ref="root"></div>'
    seen = {}
    k = Class.new(Lilac::Component) do
      define_method(:setup) do
        root.on(:thing) do |event|
          seen[:key] = event.key
          seen[:id]  = event[:detail][:id].to_i
        end
      end
    end
    Lilac.register "ev-detail", k
    Lilac.start

    inst = Lilac.find_for_element(doc.call(:querySelector, "[data-component='ev-detail']"))
    inst.root.dispatch(:thing, detail: { id: 7 })

    Spec.assert_true seen[:key].nil?
    Spec.assert_equal 7, seen[:id]
  end

  Spec.assert "once resolves with a Lilac::Event (wrapped on the Ruby side)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="ev-once"><div data-ref="box"></div></div>'
    Class.new(Lilac::Component) { define_method(:setup) {} }.tap do |k|
      Lilac.register("ev-once", k)
    end
    Lilac.start
    Lilac.flush_async!

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component='ev-once']"))
    box_js = body.call(:querySelector, "[data-component='ev-once'] [data-ref='box']")

    JS.global.call(:setTimeout, JS.callback {
      box_js.call(:dispatchEvent, Lilac.__window__[:CustomEvent].new("ping", JS.object(detail: 9)))
    }, 0)

    event = inst.refs.box.once(:ping).await
    Spec.assert_true Lilac::Event === event
    Spec.assert_equal 9, event[:detail].to_i

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
