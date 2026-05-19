# Regression tests for previously fixed mruby-regexp-compat bugs.
# Each describe block names the commit that introduced the fix so
# git blame leads back to the analysis.

Spec.describe "Regexp regression: insert_inst forward-reference (f1d5067)" do
  Spec.assert "^\\w*\\??$ matches empty string" do
    # Original failure: insert_inst incremented the \w* SPLIT's offset
    # past its own forward-reference target when \?? was emitted,
    # making the empty string fail to match.
    Spec.assert_true(!!(/^\w*\??$/.match("")))
  end

  Spec.assert "^\\w*\\??$ matches single word char" do
    Spec.assert_equal "a", /^\w*\??$/.match("a")[0]
  end

  Spec.assert "^\\w*\\??$ matches word followed by ?" do
    Spec.assert_equal "abc?", /^\w*\??$/.match("abc?")[0]
  end

  Spec.assert "quantifier-after-quantifier offset is preserved" do
    # Generalized form: any pattern where a quantifier's SPLIT
    # forward-references the start of a sub-pattern that gets
    # wrapped by another quantifier.
    Spec.assert_true(!!(/^\d*\.?\d*$/.match("")))
    Spec.assert_true(!!(/^\d*\.?\d*$/.match("3.14")))
    Spec.assert_true(!!(/^\d*\.?\d*$/.match("3.")))
    Spec.assert_true(!!(/^\d*\.?\d*$/.match(".5")))
  end
end

Spec.describe "Regexp regression: String#split argc semantics (88899ae)" do
  Spec.assert "split with omitted limit drops trailing empties (MRI default)" do
    Spec.assert_equal ["a", "b"], "a,b,,,".split(",")
  end

  Spec.assert "split with explicit limit=-1 keeps trailing empties" do
    Spec.assert_equal ["a", "b", "", "", ""], "a,b,,,".split(",", -1)
  end

  Spec.assert "split with limit=0 drops trailing empties (= MRI default)" do
    Spec.assert_equal ["a", "b"], "a,b,,,".split(",", 0)
  end

  Spec.assert "split with positive limit caps field count, keeps trailing" do
    Spec.assert_equal ["a", "b,,,"], "a,b,,,".split(",", 2)
  end

  Spec.assert "split with nil pattern uses default whitespace + drop trailing" do
    Spec.assert_equal ["a", "b"], "  a  b  ".split(nil)
  end

  Spec.assert "split with regexp pattern, omitted limit drops trailing" do
    Spec.assert_equal ["a", "b"], "a,b,,,".split(/,/)
  end

  Spec.assert "split with regexp pattern, explicit -1 keeps trailing" do
    Spec.assert_equal ["a", "b", "", "", ""], "a,b,,,".split(/,/, -1)
  end

  Spec.assert "split rejects more than 2 arguments" do
    Spec.assert_raises(ArgumentError) { "a,b".split(",", -1, :extra) }
  end
end
