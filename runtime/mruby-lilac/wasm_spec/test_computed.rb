Spec.describe "Lilac::Computed" do
  Spec.assert "tracks signal deps and recomputes" do
    a = Lilac::Signal.new(1)
    b = Lilac::Signal.new(2)
    sum = Lilac::Computed.new { a.value + b.value }
    Spec.assert_equal 3, sum.value
    a.value = 10
    Spec.assert_equal 12, sum.value
    b.value = 20
    Spec.assert_equal 30, sum.value
  end

  Spec.assert "computed is read-only" do
    m = Lilac::Computed.new { 1 }
    Spec.assert_raises(NoMethodError) { m.value = 2 }
  end

  Spec.assert "effect re-runs when computed value changes" do
    s = Lilac::Signal.new(1)
    doubled = Lilac::Computed.new { s.value * 2 }
    seen = []
    Lilac::Effect.new { seen << doubled.value }
    Spec.assert_equal [2], seen
    s.value = 3
    Spec.assert_equal [2, 6], seen
  end

  Spec.assert "computed skips downstream notify when computed value unchanged" do
    s = Lilac::Signal.new(1)
    is_pos = Lilac::Computed.new { s.value > 0 }
    runs = 0
    Lilac::Effect.new { is_pos.value; runs += 1 }
    Spec.assert_equal 1, runs
    s.value = 2  # still > 0
    Spec.assert_equal 1, runs
    s.value = -1
    Spec.assert_equal 2, runs
  end

  Spec.assert "computed supports custom equals comparator" do
    s = Lilac::Signal.new("a")
    folded = Lilac::Computed.new(equals: ->(a, b) { a.to_s.downcase == b.to_s.downcase }) do
      s.value
    end
    seen = []
    Lilac::Effect.new { seen << folded.value }
    Spec.assert_equal ["a"], seen
    s.value = "A"
    Spec.assert_equal ["a"], seen
    s.value = "B"
    Spec.assert_equal ["a", "B"], seen
  end

  Spec.assert "computed supports equals: false to force downstream notify" do
    s = Lilac::Signal.new(1)
    truthy = Lilac::Computed.new(equals: false) { s.value > 0 }
    runs = 0
    Lilac::Effect.new { truthy.value; runs += 1 }
    Spec.assert_equal 1, runs
    s.value = 2
    Spec.assert_equal 2, runs
  end

  Spec.assert "computed supports on: to restrict dependency tracking" do
    trigger = Lilac::Signal.new(0)
    noisy = Lilac::Signal.new(10)
    memo = Lilac::Computed.new(on: trigger) { noisy.value * 2 }
    Spec.assert_equal 20, memo.value
    noisy.value = 11
    Spec.assert_equal 20, memo.value
    trigger.value = 1
    Spec.assert_equal 22, memo.value
  end

end
