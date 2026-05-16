# Top-level classes used by the autoregister tests below. Defined here
# (not via Class.new) so Ruby constant resolution can find them.
class AutoCounter < Lilac::Component
  def setup
    @ran = signal(:auto_counter_ran)
  end
end

module AutoNs
  class InnerCard < Lilac::Component
    def setup
      @ran = signal(:inner_card_ran)
    end
  end
end

# Used to verify the "constant exists but isn't a Component subclass" error
# path. Resolved by data-component="resolve-not-a-component".
class ResolveNotAComponent; end

Spec.describe "Component autoregister (naming convention)" do
  Spec.after { Lilac.reset! }

  Spec.assert "top-level constant resolves via kebab-to-CamelCase" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="auto-counter"></div>'

    Lilac.start

    el = doc.call(:querySelector, "[data-component='auto-counter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true inst.is_a?(AutoCounter)

    body[:innerHTML] = ""
  end

  Spec.assert "namespaced constant resolves via `--` separator" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="auto-ns--inner-card"></div>'

    Lilac.start

    el = doc.call(:querySelector, "[data-component='auto-ns--inner-card']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true inst.is_a?(AutoNs::InnerCard)

    body[:innerHTML] = ""
  end

  Spec.assert "explicit Lilac.register wins over a same-named top-level constant" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="auto-counter"></div>'

    override = Class.new(Lilac::Component) do
      define_method(:setup) { @from_override = signal(true) }
    end
    Lilac.register "auto-counter", override
    Lilac.start

    el = doc.call(:querySelector, "[data-component='auto-counter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_false inst.is_a?(AutoCounter)
    Spec.assert_true inst.is_a?(override)

    body[:innerHTML] = ""
  end

  Spec.assert "constant resolves but is not a Component subclass -> Lilac::Error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="resolve-not-a-component"></div>'

    Spec.assert_raises(Lilac::Error) { Lilac.start }

    body[:innerHTML] = ""
  end

  Spec.assert "empty namespace segments -> Lilac::Error" do
    doc = JS.global[:document]
    body = doc[:body]

    body[:innerHTML] = '<div data-component="foo--"></div>'
    Spec.assert_raises(Lilac::Error) { Lilac.start }

    Lilac.reset!
    body[:innerHTML] = '<div data-component="foo----bar"></div>'
    Spec.assert_raises(Lilac::Error) { Lilac.start }

    body[:innerHTML] = ""
  end

  Spec.assert "syntactically invalid Ruby constant name -> warn + skip (no NameError leak)" do
    doc = JS.global[:document]
    body = doc[:body]
    # "123-thing" camelizes to "123Thing", which Object.const_defined?
    # rejects with NameError. The resolver must swallow that and fall
    # through to the same warn+skip path as unknown names.
    body[:innerHTML] = '<div data-component="123-thing"></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, _err) { captured << msg }

    Lilac.start  # must not raise NameError

    Spec.assert_true captured.any? { |m| m.include?("123-thing") }

    Lilac.logger = nil
    body[:innerHTML] = ""
  end

  Spec.assert "unknown name with no matching constant -> warn + skip (no raise)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="never-defined-thing"></div>'

    captured = []
    Lilac.logger = ->(_severity, msg, _err) { captured << msg }

    Lilac.start  # must not raise

    el = doc.call(:querySelector, "[data-component='never-defined-thing']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true inst.nil?
    Spec.assert_true captured.any? { |m| m.include?("never-defined-thing") }

    Lilac.logger = nil
    body[:innerHTML] = ""
  end
end
