Spec.describe "Lilac::Reactive.untrack" do
  Spec.assert "reads inside untrack do not subscribe the effect" do
    a = Lilac::Signal.new(0)
    b = Lilac::Signal.new(0)
    runs = 0
    Lilac::Effect.new do
      a.value
      Lilac::Reactive.untrack { b.value }
      runs += 1
    end
    Spec.assert_equal 1, runs

    a.value = 1   # tracked → re-runs
    Spec.assert_equal 2, runs

    b.value = 99  # untracked → no re-run
    Spec.assert_equal 2, runs

    a.value = 2   # still re-runs on a
    Spec.assert_equal 3, runs
  end

  Spec.assert "returns the block's return value" do
    s = Lilac::Signal.new(42)
    v = Lilac::Reactive.untrack { s.value }
    Spec.assert_equal 42, v
  end

  Spec.assert "untrack outside any effect is a no-op (still reads value)" do
    s = Lilac::Signal.new("hi")
    Spec.assert_equal "hi", Lilac::Reactive.untrack { s.value }
  end

  Spec.assert "nested track inside untrack re-enables tracking" do
    a = Lilac::Signal.new(0)
    b = Lilac::Signal.new(0)
    inner_runs = 0

    Lilac::Effect.new do
      a.value
      Lilac::Reactive.untrack do
        # Nested Computed creates its own tracker scope. The Computed subscribes
        # to b, but the OUTER Effect remains untracked from b.
        m = Lilac::Computed.new { b.value }
        m.value     # untracked read of computed from outer effect
        inner_runs += 1
      end
    end

    Spec.assert_equal 1, inner_runs
    b.value = 7   # outer effect doesn't subscribe to b → no re-run
    Spec.assert_equal 1, inner_runs
    a.value = 1   # outer effect re-runs because of a
    Spec.assert_equal 2, inner_runs
  end

  Spec.assert "computed inside untrack does not subscribe outer effect to its deps" do
    s = Lilac::Signal.new(10)
    m = Lilac::Computed.new { s.value * 2 }
    runs = 0
    Lilac::Effect.new do
      Lilac::Reactive.untrack { m.value }
      runs += 1
    end
    Spec.assert_equal 1, runs
    s.value = 20    # computed recomputes (it tracked s), but outer effect didn't sub to computed
    Spec.assert_equal 1, runs
  end

  Spec.assert "exception inside untrack still pops the tracker stack" do
    a = Lilac::Signal.new(0)
    runs = 0
    Lilac::Effect.new do
      a.value
      runs += 1
      begin
        Lilac::Reactive.untrack { raise "boom" }
      rescue
        # swallow
      end
    end
    Spec.assert_equal 1, runs
    # If untrack failed to pop, the next a.value= would not notify.
    a.value = 1
    Spec.assert_equal 2, runs
  end
end
