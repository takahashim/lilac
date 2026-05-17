# Tests for `validate_prop_ivars_not_overwritten!` — detecting user
# reassignment of `@X` ivars that `prop :X` auto-initialized.
# Reassignment breaks the parent → child reactive link, so we raise
# at mount with a remediation hint. See docs/lilac-props-spec.md.

class OverrideOk < Lilac::Component
  prop :title, String
  def setup; end  # no touch
end

class OverrideReassign < Lilac::Component
  prop :title, String
  def setup
    @title = signal("override")
  end
end

class OverrideToNil < Lilac::Component
  prop :title, String
  def setup
    @title = nil
  end
end

class OverrideViaIvarSet < Lilac::Component
  prop :title, String
  def setup
    instance_variable_set(:@title, "raw")
  end
end

Spec.describe "prop ivar override detection" do
  Spec.after { Lilac.reset! }

  Spec.assert "setup that does NOT touch the prop ivar mounts OK" do
    doc = JS.global[:document]
    body = doc[:body]
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    body[:innerHTML] = '<div data-component="OverrideOk" data-prop-title="hello"></div>'
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.none? { |_, msg, _| msg.include?("overwrote") }
    body[:innerHTML] = ""
  end

  Spec.assert "@title = signal(\"override\") in setup raises via logger" do
    doc = JS.global[:document]
    body = doc[:body]
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    body[:innerHTML] = '<div data-component="OverrideReassign" data-prop-title="initial"></div>'
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, msg, err|
      msg.include?("OverrideReassign") && err.is_a?(Lilac::Error) &&
        err.message.include?("overwrote `@title`") &&
        err.message.include?("prop :title")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "@title = nil in setup raises" do
    doc = JS.global[:document]
    body = doc[:body]
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    body[:innerHTML] = '<div data-component="OverrideToNil" data-prop-title="initial"></div>'
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("overwrote `@title`")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "instance_variable_set(:@title, ...) in setup raises" do
    doc = JS.global[:document]
    body = doc[:body]
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    body[:innerHTML] = '<div data-component="OverrideViaIvarSet" data-prop-title="initial"></div>'
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("overwrote `@title`")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "error message contains class name + prop name + 3 remediation options" do
    doc = JS.global[:document]
    body = doc[:body]
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    body[:innerHTML] = '<div data-component="OverrideReassign" data-prop-title="x"></div>'
    Lilac.start
    Lilac.logger = nil
    err = captured.find { |_, _, e| e.is_a?(Lilac::Error) && e.message.include?("overwrote") }&.last
    Spec.assert_true !err.nil?
    Spec.assert_true err.message.include?("OverrideReassign")
    Spec.assert_true err.message.include?("@title.value")
    Spec.assert_true err.message.include?("computed")
    Spec.assert_true err.message.include?("rename")
    body[:innerHTML] = ""
  end
end
