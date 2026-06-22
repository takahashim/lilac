Spec.describe "RefElement#closest" do
  Spec.after { Lilac.reset! }

  Spec.assert "returns the nearest matching ancestor-or-self as a RefElement" do
    doc = JS.global[:document]
    doc[:body][:innerHTML] =
      '<div data-component="cl-hit"><div class="player"><button data-ref="btn">x</button></div></div>'
    got = {}
    k = Class.new(Lilac::Component) do
      define_method(:setup) do
        got[:panel] = refs.btn.closest(".player")
        got[:self]  = refs.btn.closest("button")
        got[:none]  = refs.btn.closest(".nope")
      end
    end
    Lilac.register "cl-hit", k
    Lilac.start

    Spec.assert_true Lilac::RefElement === got[:panel]
    Spec.assert_true got[:panel].js[:classList].call(:contains, "player").js_bool
    # ancestor-or-self: matching self returns self
    Spec.assert_true Lilac::RefElement === got[:self]
    Spec.assert_equal "BUTTON", got[:self].js[:tagName].to_s
    # no match → nil
    Spec.assert_true got[:none].nil?
  end

  Spec.assert "returns nil for non-Element / null wrapped nodes (no raise)" do
    doc = JS.global[:document]
    doc[:body][:innerHTML] = '<div data-component="cl-safe"></div>'
    got = {}
    k = Class.new(Lilac::Component) do
      define_method(:setup) do
        text = JS.global[:document].call(:createTextNode, "hi")
        got[:text] = wrap(text).closest(".anything")
        missing = JS.global[:document].call(:querySelector, ".does-not-exist")
        got[:null] = wrap(missing).closest(".anything")
      end
    end
    Lilac.register "cl-safe", k
    Lilac.start

    Spec.assert_true got[:text].nil?
    Spec.assert_true got[:null].nil?
  end
end
