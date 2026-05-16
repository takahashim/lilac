Spec.describe "Lilac::Signal" do
  Spec.assert "value reads initial" do
    s = Lilac::Signal.new(42)
    Spec.assert_equal 42, s.value
  end

  Spec.assert "value= replaces and notifies" do
    s = Lilac::Signal.new(0)
    seen = []
    Lilac::Effect.new { seen << s.value }
    Spec.assert_equal [0], seen
    s.value = 1
    Spec.assert_equal [0, 1], seen
  end

  Spec.assert "value= skips notify when value is equal primitive" do
    s = Lilac::Signal.new(7)
    seen = []
    Lilac::Effect.new { seen << s.value }
    s.value = 7
    Spec.assert_equal [7], seen
  end

  Spec.assert "update applies block return as new value" do
    s = Lilac::Signal.new(1)
    s.update { |n| n + 1 }
    Spec.assert_equal 2, s.value
  end

  Spec.assert "update warns on returning same mutable object" do
    s = Lilac::Signal.new([1, 2])
    msgs = []
    Lilac.logger = ->(_severity, m, _err) { msgs << m }
    begin
      s.update { |xs| xs }  # returning same object
    ensure
      Lilac.logger = nil
    end
    Spec.assert_true msgs.any? { |m| m.include?("update returned the same mutable object") }
  end

  Spec.assert "update warns when block tries to mutate the frozen arg" do
    s = Lilac::Signal.new([1])
    msgs = []
    Lilac.logger = ->(_severity, m, _err) { msgs << m }
    err = nil
    begin
      s.update { |xs| xs << 2; xs }
    rescue => e
      err = e
    ensure
      Lilac.logger = nil
    end
    Spec.assert_true !err.nil?
    Spec.assert_true msgs.any? { |m| m.include?("Cannot mutate value inside update") }
  end

  Spec.assert "mutate yields current value, ignores return" do
    s = Lilac::Signal.new([1, 2])
    notified = 0
    Lilac::Effect.new { s.value; notified += 1 }
    s.mutate { |xs| xs << 3 }
    Spec.assert_equal [1, 2, 3], s.value
    Spec.assert_equal 2, notified  # initial run + one notify
  end

  Spec.assert "mutate raises TypeError on Numeric" do
    s = Lilac::Signal.new(0)
    Spec.assert_raises(TypeError) { s.mutate { |n| n + 1 } }
  end

  Spec.assert "mutate warns when block returns different mutable object" do
    s = Lilac::Signal.new([])
    msgs = []
    Lilac.logger = ->(_severity, m, _err) { msgs << m }
    begin
      s.mutate { |xs| xs + [1] }  # returns new array, not mutated
    ensure
      Lilac.logger = nil
    end
    Spec.assert_true msgs.any? { |m| m.include?("mutate ignores the block return value") }
  end
end

Spec.describe "Lilac::Reactive batch" do
  Spec.assert "batch defers notifications and dedups" do
    a = Lilac::Signal.new(0)
    b = Lilac::Signal.new(0)
    runs = 0
    Lilac::Effect.new { a.value; b.value; runs += 1 }
    Spec.assert_equal 1, runs
    Lilac::Reactive.batch do
      a.value = 1
      b.value = 2
      Spec.assert_equal 1, runs # not yet flushed
    end
    Spec.assert_equal 2, runs
  end
end
