Spec.describe "Component lifecycle abort" do
  # `Lilac.reset!` forcefully unmounts components registered by the
  # previous case, so the next case starts from a clean registry even
  # if the MutationObserver-based unmount hadn't flushed yet.
  Spec.after { Lilac.reset! }

  Spec.assert "alive? reflects mounted / unmounted state" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-alive"></div>'

    klass = Class.new(Lilac::Component)
    Lilac.register "ab-alive", klass
    Lilac.start

    inst = Lilac.find_for_element(doc.call(:querySelector, "[data-component='ab-alive']"))
    Spec.assert_true inst.alive?

    body[:innerHTML] = ""
    Lilac.flush_async!(16)
    Spec.assert_false inst.alive?
  end

  Spec.assert "abort_signal is a JS AbortSignal, not aborted while mounted" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-signal"></div>'

    klass = Class.new(Lilac::Component)
    Lilac.register "ab-signal", klass
    Lilac.start

    inst = Lilac.find_for_element(doc.call(:querySelector, "[data-component='ab-signal']"))
    sig = inst.abort_signal
    Spec.assert_false sig[:aborted].js_bool

    body[:innerHTML] = ""
    Lilac.flush_async!(16)
    Spec.assert_true sig[:aborted].js_bool
  end

  Spec.assert "Component#sleep raises Lilac::Aborted if already unmounted" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-pre"></div>'

    klass = Class.new(Lilac::Component)
    Lilac.register "ab-pre", klass
    Lilac.start

    inst = Lilac.find_for_element(doc.call(:querySelector, "[data-component='ab-pre']"))
    body[:innerHTML] = ""
    Lilac.flush_async!(16)

    Spec.assert_raises(Lilac::Aborted) { inst.sleep(0.01) }
  end

  Spec.assert "Aborted from sleep inside :click handler is silenced" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-click"><button data-ref="btn"></button></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, err) { captured << [msg, err] }

    reached_after_sleep = false
    boundary_fired = false
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        on_error { |_l, _e| boundary_fired = true; true }
        refs.btn.on(:click) do
          sleep(0.1)
          reached_after_sleep = true
        end
      end
    end
    Lilac.register "ab-click", klass
    Lilac.start

    btn = doc.call(:querySelector, "[data-component='ab-click'] button")
    btn.call(:click)
    Lilac.flush_async!(20)
    body[:innerHTML] = ""
    Lilac.flush_async!(200)

    Spec.assert_false reached_after_sleep
    Spec.assert_false boundary_fired
    Spec.assert_equal 0, captured.length

    Lilac.logger = nil
  end

  Spec.assert "Aborted from sleep inside every block is silenced" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-every"></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, err) { captured << [msg, err] }

    reached_after_sleep = 0
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        every(20) do
          sleep(0.2)
          reached_after_sleep += 1
        end
      end
    end
    Lilac.register "ab-every", klass
    Lilac.start

    Lilac.flush_async!(30)
    body[:innerHTML] = ""
    Lilac.flush_async!(300)

    Spec.assert_equal 0, reached_after_sleep
    Spec.assert_equal 0, captured.count { |(msg, _)| msg.to_s.include?("every") }

    Lilac.logger = nil
  end

  Spec.assert "Aborted bypasses on_error entirely (silenced at Logger#error)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-on-err"><button data-ref="btn"></button></div>'

    on_error_invocations = []
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        on_error do |label, err|
          on_error_invocations << [label, err.class]
          true
        end
        refs.btn.on(:click) do
          sleep(0.1)
        end
      end
    end
    Lilac.register "ab-on-err", klass
    Lilac.start

    btn = doc.call(:querySelector, "[data-component='ab-on-err'] button")
    btn.call(:click)
    Lilac.flush_async!(20)
    body[:innerHTML] = ""
    Lilac.flush_async!(200)

    Spec.assert_equal [], on_error_invocations
  end

  Spec.assert "non-Aborted exceptions still flow through on_error / logger" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ab-regress"><button data-ref="btn"></button></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, err) { captured << [msg, err] }

    boundary_saw = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        on_error { |label, err| boundary_saw = [label, err.message]; true }
        refs.btn.on(:click) { raise "kaboom" }
      end
    end
    Lilac.register "ab-regress", klass
    Lilac.start

    doc.call(:querySelector, "[data-component='ab-regress'] button").call(:click)
    Lilac.flush_async!(16)

    Spec.assert_true boundary_saw && boundary_saw[1] == "kaboom"
    Spec.assert_equal 0, captured.length

    Lilac.logger = nil
    body[:innerHTML] = ""
    Lilac.flush_async!(16)
  end
end
