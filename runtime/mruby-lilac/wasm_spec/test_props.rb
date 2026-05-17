# Top-level classes for props tests — defined here so the framework can
# instantiate them via data-component without explicit Lilac.register.

class PropsStringCounter < Lilac::Component
  prop :label, String
  # `prop :label` auto-initializes @label as a Signal at mount;
  # no setup needed.
end

class PropsIntCounter < Lilac::Component
  prop :initial, Integer, default: 0
  prop :step,    Integer, default: 1

  def setup
    @count = signal(props.initial)
    @step_value = props.step
  end
end

class PropsFloatCounter < Lilac::Component
  prop :rate, Float, default: 1.0

  def setup
    @rate_value = props.rate
  end
end

class PropsBoolCounter < Lilac::Component
  prop :enabled,  Lilac::Boolean
  prop :disabled, Lilac::Boolean, default: false
  # @enabled / @disabled are auto-initialized as Signals at mount.
end

class PropsKebabName < Lilac::Component
  prop :max_length, Integer, default: 100

  def setup
    @max = props.max_length
  end
end

class PropsRequiredMissing < Lilac::Component
  prop :must_have, String

  def setup
    @ran = signal(true)
  end
end

class PropsIntInvalid < Lilac::Component
  prop :step, Integer

  def setup
    @s = signal(true)
  end
end

class PropsBoolInvalid < Lilac::Component
  prop :flag, Lilac::Boolean

  def setup
    @s = signal(true)
  end
end

class PropsNilDefault < Lilac::Component
  prop :nullable, String, default: nil

  def setup
    @v = props.nullable
  end
end

class PropsHasTo < Lilac::Component
  prop :a, String
  prop :b, Integer, default: 5

  def setup
    @has_a = props.has?(:a)
    @has_b = props.has?(:b)
    @hash  = props.to_h
  end
end

# Inheritance: child class adds new prop, inherits parent's prop.
class PropsParentBase < Lilac::Component
  prop :inherited, String, default: "from-parent"
end

class PropsChild < PropsParentBase
  prop :own, Integer, default: 7
  # @inherited (from parent) and @own are auto-initialized as Signals.
end

class PropsNoDecl < Lilac::Component
  def setup
    @ran = signal(true)
  end
end

Spec.describe "Component props" do
  Spec.after { Lilac.reset! }

  Spec.assert "String prop reads from data-prop-*" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsStringCounter" data-prop-label="Email"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsStringCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "Email", inst.props.label
    body[:innerHTML] = ""
  end

  Spec.assert "Integer prop converts string to Integer" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsIntCounter" data-prop-initial="10" data-prop-step="3"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsIntCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal 10, inst.props.initial
    Spec.assert_equal 3, inst.props.step
    body[:innerHTML] = ""
  end

  Spec.assert "Integer prop default applied when attribute missing" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsIntCounter"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsIntCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal 0, inst.props.initial
    Spec.assert_equal 1, inst.props.step
    body[:innerHTML] = ""
  end

  Spec.assert "Float prop converts string to Float" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsFloatCounter" data-prop-rate="0.75"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsFloatCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal 0.75, inst.props.rate
    body[:innerHTML] = ""
  end

  Spec.assert "Boolean prop: 'true' → true, 'false' → false" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsBoolCounter" data-prop-enabled="true" data-prop-disabled="false"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsBoolCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal true,  inst.props.enabled
    Spec.assert_equal false, inst.props.disabled
    body[:innerHTML] = ""
  end

  Spec.assert "Boolean prop: presence shortcut → true" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsBoolCounter" data-prop-enabled></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsBoolCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal true,  inst.props.enabled
    Spec.assert_equal false, inst.props.disabled  # default
    body[:innerHTML] = ""
  end

  Spec.assert "Boolean prop: empty value attribute → true" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsBoolCounter" data-prop-enabled=""></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsBoolCounter']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal true, inst.props.enabled
    body[:innerHTML] = ""
  end

  Spec.assert "kebab-case attribute → snake_case method name" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsKebabName" data-prop-max-length="200"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsKebabName']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal 200, inst.props.max_length
    body[:innerHTML] = ""
  end

  Spec.assert "required prop without default routes through logger.error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsRequiredMissing"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    Lilac.start                                  # does NOT raise (routed via error_boundary path)
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, msg, err|
      msg.include?("PropsRequiredMissing") && err.is_a?(Lilac::Error) && err.message.include?(":must_have")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "Integer type mismatch routes through logger.error with attribute key" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsIntInvalid" data-prop-step="abc"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("data-prop-step") && err.message.include?("Integer")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "Boolean type rejects 'yes' / '1' / 'on' via logger.error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsBoolInvalid" data-prop-flag="yes"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("Boolean")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "default: nil allows nil value when attribute missing" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsNilDefault"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsNilDefault']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal nil, inst.props.nullable
    body[:innerHTML] = ""
  end

  Spec.assert "props.has? and to_h reflect declared vs default state" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsHasTo" data-prop-a="hello"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsHasTo']")
    inst = Lilac.find_for_element(el)
    # :a came from attribute, :b from default
    Spec.assert_equal true, inst.props.has?(:a)
    Spec.assert_equal true, inst.props.has?(:b)
    Spec.assert_equal false, inst.props.has?(:nonexistent)
    h = inst.props.to_h
    Spec.assert_equal "hello", h[:a]
    Spec.assert_equal 5, h[:b]
    body[:innerHTML] = ""
  end

  Spec.assert "subclass inherits parent prop declarations" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsChild" data-prop-inherited="from-html" data-prop-own="42"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsChild']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "from-html", inst.props.inherited
    Spec.assert_equal 42, inst.props.own
    body[:innerHTML] = ""
  end

  Spec.assert "subclass inherits parent prop default when attr missing" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsChild"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsChild']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "from-parent", inst.props.inherited
    Spec.assert_equal 7, inst.props.own
    body[:innerHTML] = ""
  end

  Spec.assert "undeclared data-prop-* attribute warns in dev_mode but does not crash" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsNoDecl" data-prop-foo="bar"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, _err) { captured << [severity, msg] }
    Lilac.start                                  # dev_mode is default true
    Lilac.logger = nil
    el = doc.call(:querySelector, "[data-component='PropsNoDecl']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true !inst.nil?
    Spec.assert_true captured.any? { |sev, msg| sev == :warn && msg.include?("data-prop-foo") }
    body[:innerHTML] = ""
  end

  Spec.assert "warn_unknown is skipped when dev_mode is false" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsNoDecl" data-prop-foo="bar"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, _err) { captured << [severity, msg] }
    saved_dev_mode = Lilac.dev_mode
    Lilac.dev_mode = false
    Lilac.start
    Lilac.dev_mode = saved_dev_mode
    Lilac.logger = nil
    Spec.assert_true captured.none? { |sev, msg| sev == :warn && msg.include?("data-prop-foo") }
    body[:innerHTML] = ""
  end

  Spec.assert "accessing undeclared prop via method_missing raises NoMethodError" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PropsStringCounter" data-prop-label="X"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PropsStringCounter']")
    inst = Lilac.find_for_element(el)
    raised = false
    begin
      inst.props.unknown_thing
    rescue NoMethodError
      raised = true
    end
    Spec.assert_true raised
    body[:innerHTML] = ""
  end
end
