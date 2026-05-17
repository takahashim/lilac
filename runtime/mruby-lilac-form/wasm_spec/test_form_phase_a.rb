# Phase A additions: dual-purpose `form`, FieldComponent + source:,
# f.button + invoke_button, form.reset propagation.

# ---- FieldComponent top-level classes (data-component resolution) ----

class PhaseACountryPicker < Lilac::FieldComponent
  # default initial_value "" inherited; override would go here.

  def setup
    super
    @initial_options = signal(["asia", "americas", "europe"])
  end
end

class PhaseADatePicker < Lilac::FieldComponent
  def setup
    super
    @year = signal(2024)
    @month = signal(6)
    @day = signal(15)
    # Override @value as a Computed — composite read-only value backed by
    # underlying signals. Form#reset must invoke our reset, not write @value.
    @value = computed { "#{@year.value}-#{@month.value}-#{@day.value}" }
  end

  def reset
    @year.value = 2024
    @month.value = 6
    @day.value = 15
    nil
  end
end

class PhaseAFormHost < Lilac::Component
  attr_reader :submit_payload
  def setup
    @submit_payload = nil
    form do |f|
      f.field :country, source: refs.country.component do |field|
        "required" if field.value.nil? || field.value.empty?
      end
      f.field :date, source: refs.date.component
      f.button :submit do |values|
        @submit_payload = values
      end
    end
  end
end

Spec.describe "Lilac::FieldComponent base + Form source:" do
  Spec.after { Lilac.reset! }

  Spec.assert "FieldComponent exposes value signal initialized to initial_value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PhaseACountryPicker"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PhaseACountryPicker']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "", inst.value.value
    inst.value.value = "asia"
    Spec.assert_equal "asia", inst.value.value
    body[:innerHTML] = ""
  end

  Spec.assert "FieldComponent#reset restores initial_value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="PhaseACountryPicker"></div>'
    Lilac.start
    el = doc.call(:querySelector, "[data-component='PhaseACountryPicker']")
    inst = Lilac.find_for_element(el)
    inst.value.value = "americas"
    inst.reset
    Spec.assert_equal "", inst.value.value
    body[:innerHTML] = ""
  end

  Spec.assert "f.field source: FieldComponent shares the signal (two-way)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="PhaseAFormHost">
        <div data-component="PhaseACountryPicker" data-ref="country"></div>
        <div data-component="PhaseADatePicker" data-ref="date"></div>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='PhaseAFormHost']")
    host = Lilac.find_for_element(host_el)
    picker_el = doc.call(:querySelector, "[data-component='PhaseACountryPicker']")
    picker = Lilac.find_for_element(picker_el)

    # Writing through the child's signal should be visible via form[:country].
    picker.value.value = "europe"
    Spec.assert_equal "europe", host.form[:country].value

    # Writing through form should be visible on the child.
    host.form[:country].value = "asia"
    Spec.assert_equal "asia", picker.value.value
    body[:innerHTML] = ""
  end

  Spec.assert "form.reset propagates to FieldComponent source via reset" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="PhaseAFormHost">
        <div data-component="PhaseACountryPicker" data-ref="country"></div>
        <div data-component="PhaseADatePicker" data-ref="date"></div>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='PhaseAFormHost']")
    host = Lilac.find_for_element(host_el)
    picker_el = doc.call(:querySelector, "[data-component='PhaseACountryPicker']")
    picker = Lilac.find_for_element(picker_el)
    date_el = doc.call(:querySelector, "[data-component='PhaseADatePicker']")
    date = Lilac.find_for_element(date_el)

    picker.value.value = "europe"
    date.instance_variable_get(:@year).value = 2030
    Spec.assert_equal "europe", host.form[:country].value
    Spec.assert_equal "2030-6-15", host.form[:date].value

    host.form.reset
    Spec.assert_equal "", picker.value.value
    Spec.assert_equal "2024-6-15", date.value.value
    body[:innerHTML] = ""
  end

  Spec.assert "Computed-backed FieldComponent value is read-only via form[:x].value=" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="PhaseAFormHost">
        <div data-component="PhaseACountryPicker" data-ref="country"></div>
        <div data-component="PhaseADatePicker" data-ref="date"></div>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='PhaseAFormHost']")
    host = Lilac.find_for_element(host_el)
    # Writing to a Computed-backed field should silently no-op
    # (Computed has no value= unless mruby-lilac defines one).
    raised = false
    begin
      host.form[:date].value = "ignored"
    rescue NoMethodError
      raised = true
    end
    Spec.assert_true raised   # Lilac::Computed has no value= setter
    body[:innerHTML] = ""
  end
end

Spec.describe "Component#form dual-purpose registry" do
  Spec.after { Lilac.reset! }

  Spec.assert "block-less form() returns same instance as block-with" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dual-form-1"></div>'
    captured = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        registered = form { |_f| }
        looked_up = form
        captured = (registered.equal?(looked_up))
      end
    end
    Lilac.register "dual-form-1", klass
    Lilac.start
    Spec.assert_true captured
    body[:innerHTML] = ""
  end

  Spec.assert "block-less form(:name) auto-creates when missing" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dual-form-2"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :captured
      define_method(:setup) do
        @captured = form(:search)   # no prior registration; auto-create
      end
    end
    Lilac.register "dual-form-2", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='dual-form-2']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true inst.captured.is_a?(Lilac::Form)
    # Same instance returned on second lookup.
    Spec.assert_true inst.captured.equal?(inst.form(:search))
    body[:innerHTML] = ""
  end

  Spec.assert "same-name re-registration routes through error_boundary" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dual-form-3"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        form { |_f| }
        form { |_f| }   # second registration → raise → routed via setup's rescue
      end
    end
    Lilac.register "dual-form-3", klass
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("already declared")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "named forms are independent (separate registries by name)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dual-form-4"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :a, :b
      define_method(:setup) do
        @a = form(:login)
        @b = form(:signup)
      end
    end
    Lilac.register "dual-form-4", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='dual-form-4']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true !inst.a.equal?(inst.b)
    body[:innerHTML] = ""
  end
end

Spec.describe "Form#button + invoke_button" do
  Spec.after { Lilac.reset! }

  Spec.assert "f.button :submit registers handler invoked via invoke_button" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="btn-1"><input data-ref="x"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :form_ref, :got
      define_method(:setup) do
        @form_ref = form do |f|
          f.field :x, ref: refs.x, initial: "hi"
          f.button :submit do |values|
            @got = values
          end
        end
      end
    end
    Lilac.register "btn-1", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='btn-1']")
    inst = Lilac.find_for_element(el)
    inst.form_ref.invoke_button(:submit)
    Spec.assert_equal "hi", inst.got[:x]
    body[:innerHTML] = ""
  end

  Spec.assert "f.button validate: false skips validity check and touches" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="btn-2"><input data-ref="x"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :form_ref, :got
      define_method(:setup) do
        @form_ref = form do |f|
          f.field :x, ref: refs.x, initial: "" do |field|
            "required" if field.value.empty?
          end
          f.button :draft, validate: false do |values|
            @got = values
          end
        end
      end
    end
    Lilac.register "btn-2", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='btn-2']")
    inst = Lilac.find_for_element(el)
    inst.form_ref.invoke_button(:draft)
    # invalid form (x is empty) but draft skipped validation
    Spec.assert_equal "", inst.got[:x]
    # submit_attempted should remain false
    Spec.assert_equal false, inst.form_ref.submit_attempted?
    body[:innerHTML] = ""
  end

  Spec.assert "invoke_button on unknown name raises" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="btn-3"><input data-ref="x"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :form_ref
      define_method(:setup) do
        @form_ref = form do |f|
          f.field :x, ref: refs.x, initial: ""
        end
      end
    end
    Lilac.register "btn-3", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='btn-3']")
    inst = Lilac.find_for_element(el)
    raised = false
    begin
      inst.form_ref.invoke_button(:never_declared)
    rescue Lilac::Error
      raised = true
    end
    Spec.assert_true raised
    body[:innerHTML] = ""
  end
end

Spec.describe "f.field optional ref:/initial: + deferred bind" do
  Spec.after { Lilac.reset! }

  Spec.assert "f.field without ref: returns unbound field; bind_to attaches later" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="deferred-1"><input data-ref="email"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :form_ref
      define_method(:setup) do
        @form_ref = form do |f|
          f.field :email, initial: ""   # no ref: yet
        end
        form[:email].bind_to(refs.email)
      end
    end
    Lilac.register "deferred-1", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='deferred-1']")
    inst = Lilac.find_for_element(el)
    # bind_to wired the input → typing should flow into form[:email].value
    input = doc.call(:querySelector, "input[data-ref='email']")
    input[:value] = "hi@example.com"
    input.call(:dispatchEvent, JS.global[:Event].new("input"))
    Spec.assert_equal "hi@example.com", inst.form_ref[:email].value
    body[:innerHTML] = ""
  end

  Spec.assert "double bind_to raises" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="deferred-2"><input data-ref="a"><input data-ref="b"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        form do |f|
          f.field :x, initial: ""
        end
        form[:x].bind_to(refs.a)
        form[:x].bind_to(refs.b)   # already bound → raise → routed
      end
    end
    Lilac.register "deferred-2", klass
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?("already bound")
    }
    body[:innerHTML] = ""
  end

  Spec.assert "f.field without initial: uses type-based default" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="default-init"><input data-ref="t"><input type="checkbox" data-ref="c"></div>'
    klass = Class.new(Lilac::Component) do
      attr_reader :form_ref
      define_method(:setup) do
        @form_ref = form do |f|
          f.field :t, ref: refs.t              # text default → ""
          f.field :c, ref: refs.c, type: :checkbox  # checkbox default → false
        end
      end
    end
    Lilac.register "default-init", klass
    Lilac.start
    el = doc.call(:querySelector, "[data-component='default-init']")
    inst = Lilac.find_for_element(el)
    Spec.assert_equal "", inst.form_ref[:t].value
    Spec.assert_equal false, inst.form_ref[:c].value
    body[:innerHTML] = ""
  end
end

Spec.describe "f.field duplicate declaration" do
  Spec.after { Lilac.reset! }

  Spec.assert "declaring same field twice raises" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dup-field"><input data-ref="x"></div>'
    captured = []
    Lilac.logger = ->(severity, msg, err) { captured << [severity, msg, err] }
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        form do |f|
          f.field :x, ref: refs.x, initial: ""
          f.field :x, initial: ""   # duplicate → raise → routed via setup
        end
      end
    end
    Lilac.register "dup-field", klass
    Lilac.start
    Lilac.logger = nil
    Spec.assert_true captured.any? { |_, _, err|
      err.is_a?(Lilac::Error) && err.message.include?(":x") && err.message.include?("already declared")
    }
    body[:innerHTML] = ""
  end
end
