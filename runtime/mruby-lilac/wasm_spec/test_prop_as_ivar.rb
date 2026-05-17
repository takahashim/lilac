# Tests for `prop :X` auto-initializing `@X` as a Signal ivar at mount time
# (declarative-pattern foundation). See docs/lilac-props-spec.md.

class PropIvarString < Lilac::Component
  prop :greeting, String
  # No setup; @greeting is auto-init as Signal.
end

class PropIvarInteger < Lilac::Component
  prop :count, Integer, default: 0
end

class PropIvarBool < Lilac::Component
  prop :enabled, Lilac::Boolean, default: false
end

class PropIvarMutate < Lilac::Component
  prop :title, String

  def setup
    @title.value = "mutated"  # identity-preserving update (allowed)
  end
end

class PropIvarUpdateTarget < Lilac::Component
  prop :n, Integer, default: 0
end

Spec.describe "prop declares an auto-init Signal ivar" do
  Spec.after { Lilac.reset! }

  Spec.assert "prop :greeting sets @greeting as a Signal at mount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarString" data-prop-greeting="Hello"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarString']")
    inst = Lilac.find_for_element(el)
    sig = inst.instance_variable_get(:@greeting)
    Spec.assert_true sig.is_a?(Lilac::Signal)
    Spec.assert_equal "Hello", sig.value
    body[:innerHTML] = ""
  end

  Spec.assert "props.X read-through accessor returns Signal.value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarString" data-prop-greeting="Bonjour"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarString']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "Bonjour", inst.props.greeting
    body[:innerHTML] = ""
  end

  Spec.assert "Integer prop value is coerced and stored in Signal" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarInteger" data-prop-count="42"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarInteger']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal 42, inst.instance_variable_get(:@count).value
    body[:innerHTML] = ""
  end

  Spec.assert "Boolean prop value is coerced and stored in Signal" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarBool" data-prop-enabled="true"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarBool']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal true, inst.instance_variable_get(:@enabled).value
    body[:innerHTML] = ""
  end

  Spec.assert "@title.value = ... in setup is allowed (identity preserved)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarMutate" data-prop-title="initial"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarMutate']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "mutated", inst.instance_variable_get(:@title).value
    body[:innerHTML] = ""
  end

  Spec.assert "update_prop mutates the existing Signal (identity preserved)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarUpdateTarget" data-prop-n="1"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarUpdateTarget']")
    inst = Lilac.find_for_element(el)
    original_sig = inst.instance_variable_get(:@n)
    inst.update_prop(:n, "99")
    current_sig = inst.instance_variable_get(:@n)
    Spec.assert_true original_sig.equal?(current_sig)
    Spec.assert_equal 99, current_sig.value
    body[:innerHTML] = ""
  end

  Spec.assert "update_prop with bad type raises" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarUpdateTarget" data-prop-n="1"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarUpdateTarget']")
    inst = Lilac.find_for_element(el)
    raised = false
    begin
      inst.update_prop(:n, "abc")
    rescue Lilac::Error => e
      raised = e.message.include?("Integer")
    end
    Spec.assert_true raised
    body[:innerHTML] = ""
  end

  Spec.assert "update_prop with undeclared name raises" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropIvarUpdateTarget" data-prop-n="1"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropIvarUpdateTarget']")
    inst = Lilac.find_for_element(el)
    raised = false
    begin
      inst.update_prop(:nonexistent, "x")
    rescue Lilac::Error => e
      raised = e.message.include?("no such prop")
    end
    Spec.assert_true raised
    body[:innerHTML] = ""
  end

  Spec.assert "prop with reserved name raises at declaration time" do
    raised_root = false
    begin
      Class.new(Lilac::Component) { prop :root, String }
    rescue Lilac::Error => e
      raised_root = e.message.include?(":root") && e.message.include?("reserved")
    end
    Spec.assert_true raised_root

    raised_props = false
    begin
      Class.new(Lilac::Component) { prop :props, String }
    rescue Lilac::Error => e
      raised_props = e.message.include?(":props") && e.message.include?("reserved")
    end
    Spec.assert_true raised_props

    raised_refs = false
    begin
      Class.new(Lilac::Component) { prop :refs, String }
    rescue Lilac::Error => e
      raised_refs = e.message.include?(":refs") && e.message.include?("reserved")
    end
    Spec.assert_true raised_refs
  end
end
