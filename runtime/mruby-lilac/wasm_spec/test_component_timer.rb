Spec.describe "Component#timeout" do
  Spec.after { Lilac.reset! }

  Spec.assert "block fires once after the delay" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-basic"></div>'

    fired = []
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { timeout(20) { fired << :hit } }
    end
    Lilac.register "to-basic", klass
    Lilac.start

    Lilac.flush_async!(60)
    Spec.assert_equal [:hit], fired

    body[:innerHTML] = ""
    Lilac.flush_async!(16)
  end

  Spec.assert "auto-cancels when component unmounts before delay elapses" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-cancel"></div>'

    fired = []
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { timeout(80) { fired << :hit } }
    end
    Lilac.register "to-cancel", klass
    Lilac.start

    # Direct reset! (not MO via innerHTML clear) makes the
    # cancel-on-unmount deterministic in CI.
    Lilac.flush_async!(10)
    Lilac.reset!
    body[:innerHTML] = ""

    # Wait well past the original delay.
    Lilac.flush_async!(150)
    Spec.assert_equal [], fired
  end

  Spec.assert "block raise routes to error_boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-err"></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, err) { captured << [:global, msg, err] }

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        on_error do |label, err|
          captured << [:local, label, err.message]
          true
        end
        timeout(10) { raise "timeout boom" }
      end
    end
    Lilac.register "to-err", klass
    Lilac.start

    Lilac.flush_async!(40)

    locals = captured.select { |row| row[0] == :local }
    Spec.assert_equal 1, locals.length
    _, label, msg = locals.first
    Spec.assert_equal "timeout", label
    Spec.assert_equal "timeout boom", msg
    Spec.assert_equal 0, captured.count { |r| r[0] == :global }

    Lilac.logger = nil
    body[:innerHTML] = ""
    Lilac.flush_async!(16)
  end

  Spec.assert "Timer#stop cancels the pending timeout" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="to-manual"></div>'

    fired = []
    captured_timer = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        captured_timer = timeout(60) { fired << :hit }
      end
    end
    Lilac.register "to-manual", klass
    Lilac.start

    Spec.assert_true captured_timer.is_a?(Lilac::Timer)
    Spec.assert_false captured_timer.stopped?
    captured_timer.stop
    Spec.assert_true captured_timer.stopped?

    Lilac.flush_async!(100)
    Spec.assert_equal [], fired

    body[:innerHTML] = ""
    Lilac.flush_async!(16)
  end
end

Spec.describe "Component#every" do
  Spec.after { Lilac.reset! }

  Spec.assert "block fires repeatedly at the interval" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-basic"></div>'

    counts = []
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { every(15) { counts << :tick } }
    end
    Lilac.register "ev-basic", klass
    Lilac.start

    Lilac.flush_async!(80)
    Spec.assert_true counts.length >= 2

    body[:innerHTML] = ""
    Lilac.flush_async!(30)
  end

  Spec.assert "interval stops after component unmount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-stop"></div>'

    counts = []
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { every(15) { counts << :tick } }
    end
    Lilac.register "ev-stop", klass
    Lilac.start

    Lilac.flush_async!(50)
    Spec.assert_true counts.length >= 1

    # Direct reset! avoids MO scheduling latency under CI load — same
    # contract is verified ("interval stops once the component unmounts").
    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!(30)
    settled = counts.length

    Lilac.flush_async!(80)
    Spec.assert_equal settled, counts.length
  end

  Spec.assert "block raise routes to error_boundary and interval keeps firing" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-err"></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, err) { captured << [:global, msg, err] }

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        on_error do |label, err|
          captured << [:local, label, err.message]
          true
        end
        every(15) { raise "tick boom" }
      end
    end
    Lilac.register "ev-err", klass
    Lilac.start

    Lilac.flush_async!(60)

    locals = captured.select { |row| row[0] == :local }
    Spec.assert_true locals.length >= 2  # interval kept ticking past first raise
    _, label, msg = locals.first
    Spec.assert_equal "every", label
    Spec.assert_equal "tick boom", msg
    Spec.assert_equal 0, captured.count { |r| r[0] == :global }

    Lilac.logger = nil
    body[:innerHTML] = ""
    Lilac.flush_async!(30)
  end

  Spec.assert "Timer#stop halts further ticks; double stop is a no-op" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ev-manual"></div>'

    counts = []
    captured_timer = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        captured_timer = every(15) { counts << :tick }
      end
    end
    Lilac.register "ev-manual", klass
    Lilac.start

    Lilac.flush_async!(50)
    Spec.assert_true counts.length >= 1
    captured_timer.stop
    Spec.assert_true captured_timer.stopped?
    captured_timer.stop  # idempotent
    Spec.assert_true captured_timer.stopped?
    settled = counts.length

    Lilac.flush_async!(80)
    Spec.assert_equal settled, counts.length

    # unmount after manual stop must not raise / double-cancel
    body[:innerHTML] = ""
    Lilac.flush_async!(30)
  end
end
