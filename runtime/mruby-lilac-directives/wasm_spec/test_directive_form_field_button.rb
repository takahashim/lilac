# Scanner-side dispatch for data-form / data-field / data-button.
# Covers: <form> submit auto-wire, data-button click wire, data-field
# bind_to with auto-register, scope validation (non-form raise, multiple
# bare <form> raise, <input form="..."> warn), source: + FieldComponent
# integration end-to-end.

class FBSubmitForm < Lilac::Component
  attr_reader :got
  def setup
    @got = nil
    # No `f.field :email` — auto-register picks up HTML `value=` so the
    # test can verify both auto-register AND submit-event wiring in one flow.
    form do |f|
      f.button :submit do |values|
        @got = values[:email]
      end
    end
  end
end

class FBNamedForm < Lilac::Component
  attr_reader :got
  def setup
    @got = nil
    form(:signup) do |f|
      f.button :submit do |values|
        @got = values[:email]
      end
    end
  end
end

class FBDataButton < Lilac::Component
  attr_reader :saved_draft
  def setup
    @saved_draft = false
    form do |f|
      f.button :save_draft, validate: false do |values|
        @saved_draft = values[:title]
      end
    end
  end
end

class FBAutoRegister < Lilac::Component
  def setup
    # Empty form — fields will auto-register from data-field elements
    form { |_f| }
  end
end

class FBFieldComponentValue < Lilac::FieldComponent
  def setup
    super
    @options = signal(%w[a b c])
  end
end

class FBFormWithComponent < Lilac::Component
  attr_reader :submitted
  def setup
    @submitted = nil
    form do |f|
      f.field :pick, source: refs.picker.component
      f.button :submit do |values|
        @submitted = values[:pick]
      end
    end
  end
end

class FBPlainComponent < Lilac::Component
  def setup; end
end

Spec.describe "Scanner: <form> submit auto-wire" do
  Spec.after { Lilac.reset! }

  Spec.assert "plain <form> + data-field + <button type=submit> wires :submit handler" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBSubmitForm">
        <form>
          <input data-field="email" value="hi@example.com">
          <button type="submit">Send</button>
        </form>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='FBSubmitForm']")
    host = Lilac.find_for_element(host_el)
    # Verify form registered with :submit handler and auto-registered field.
    Spec.assert_true host.form.fields.key?(:email)
    Spec.assert_equal "hi@example.com", host.form[:email].value
    # Invoke via programmatic submit (DOM submit event handling under
    # happy-dom is brittle for synthetic form events). Scanner's submit
    # wiring is unit-tested via the named-form test below.
    host.form.invoke_button(:submit)
    Spec.assert_equal "hi@example.com", host.got
    body[:innerHTML] = ""
  end

  Spec.assert "named <form data-form='signup'> resolves to form(:signup) scope" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBNamedForm">
        <form data-form="signup">
          <input data-field="email" value="x@y.z">
          <button type="submit">Sign up</button>
        </form>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='FBNamedForm']")
    host = Lilac.find_for_element(host_el)
    form_el = doc.call(:querySelector, "form[data-form='signup']")
    ev = JS.global[:document][:defaultView][:Event]
    form_el.call(:dispatchEvent, ev.new("submit", JS.object(bubbles: true, cancelable: true)))
    Spec.assert_equal "x@y.z", host.got
    body[:innerHTML] = ""
  end
end

Spec.describe "Scanner: data-button click wire" do
  Spec.after { Lilac.reset! }

  Spec.assert "<button data-button='save_draft'> click invokes named action" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBDataButton">
        <form>
          <input data-field="title" value="draft1">
          <button type="button" data-button="save_draft">Save</button>
        </form>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='FBDataButton']")
    host = Lilac.find_for_element(host_el)
    btn = doc.call(:querySelector, "button[data-button='save_draft']")
    btn.call(:click)
    Spec.assert_equal "draft1", host.saved_draft
    body[:innerHTML] = ""
  end

  Spec.assert "data-button with undeclared name routes through logger.error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBDataButton">
        <form>
          <input data-field="title">
          <button type="button" data-button="ghost">X</button>
        </form>
      </div>
    HTML
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("ghost")
    }
    body[:innerHTML] = ""
  end
end

Spec.describe "Scanner: data-field auto-register" do
  Spec.after { Lilac.reset! }

  Spec.assert "data-field with no Ruby declaration auto-registers (text)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBAutoRegister">
        <form>
          <input data-field="query" value="initial-value">
        </form>
      </div>
    HTML
    captured = []
    Lilac.logger = ->(severity, msg, _err) { captured << [severity, msg] }
    Lilac.start
    Lilac.logger = nil
    host_el = doc.call(:querySelector, "[data-component='FBAutoRegister']")
    host = Lilac.find_for_element(host_el)
    Spec.assert_equal "initial-value", host.form[:query].value
    Spec.assert_true captured.any? { |sev, msg| sev == :warn && msg.include?("auto-registered field :query") }
    body[:innerHTML] = ""
  end

  Spec.assert "data-field auto-register checkbox uses :checkbox type" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBAutoRegister">
        <form>
          <input type="checkbox" data-field="agree">
        </form>
      </div>
    HTML
    Lilac.logger = ->(_s, _m, _e) {}   # suppress auto-register warn
    Lilac.start
    Lilac.logger = nil
    host_el = doc.call(:querySelector, "[data-component='FBAutoRegister']")
    host = Lilac.find_for_element(host_el)
    Spec.assert_equal false, host.form[:agree].value   # checkbox default
    body[:innerHTML] = ""
  end
end

Spec.describe "Scanner: scope validation" do
  Spec.after { Lilac.reset! }

  Spec.assert "data-form on non-<form> element routes through logger.error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="FBPlainComponent"><div data-form="x"><input data-field="y"></div></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("data-form is only allowed on <form>")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "multiple plain <form> in same component routes through logger.error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBPlainComponent">
        <form><input data-field="a"></form>
        <form><input data-field="b"></form>
      </div>
    HTML
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?(":default scope")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "<input form='...'> attribute emits dev_mode warn" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBPlainComponent">
        <form id="x"><input data-field="a"></form>
        <input form="x" data-field="b">
      </div>
    HTML
    captured = []
    Lilac.logger = ->(severity, msg, _err) { captured << [severity, msg] }
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |sev, msg| sev == :warn && msg.include?("form attribute") || msg.include?("`form` attribute") }
    body[:innerHTML] = ""
  end
end

Spec.describe "Scanner: source: FieldComponent end-to-end" do
  Spec.after { Lilac.reset! }

  Spec.assert "child FieldComponent's value flows through form on submit" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBFormWithComponent">
        <form>
          <div data-component="FBFieldComponentValue" data-ref="picker"></div>
          <button type="submit">Go</button>
        </form>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='FBFormWithComponent']")
    host = Lilac.find_for_element(host_el)
    picker_el = doc.call(:querySelector, "[data-component='FBFieldComponentValue']")
    picker = Lilac.find_for_element(picker_el)
    picker.value.value = "selected-value"

    # Form sees child's value through source: (sanity check before submit).
    Spec.assert_equal "selected-value", host.form[:pick].value
    # Invoke submit programmatically (DOM submit dispatch validated
    # separately in the named-form test above).
    host.form.invoke_button(:submit)
    Spec.assert_equal "selected-value", host.submitted
    body[:innerHTML] = ""
  end
end
