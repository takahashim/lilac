# Phase B-2: container class wiring, error slot, and 2-phase processing
# (DOM-order-independent dispatch).

class FBContainerClass < Lilac::Component
  def setup
    form do |f|
      f.field :email, initial: "" do |field|
        "required" if field.value.empty?
      end
    end
  end
end

class FBErrorSlot < Lilac::Component
  def setup
    form do |f|
      f.field :email, initial: "" do |field|
        "must include @" unless field.value.include?("@")
      end
    end
  end
end

class FB2Phase < Lilac::Component
  def setup
    form do |f|
      f.button :save do |_v|
        @saved = true
      end
    end
  end
end

class FB2PhaseLazyComputed < Lilac::Component
  # Stresses the lazy-Computed + 2-phase combo: @derived is created in
  # setup BEFORE scanner runs, references a field that's auto-registered
  # by the scanner. Without lazy Computed, the block would fire eagerly
  # during setup and raise on form[:query] (not yet registered).
  def setup
    form { |_f| }
    @derived = computed do
      form[:query].value.upcase
    end
  end
end

Spec.describe "Scanner: container class wiring" do
  Spec.after { Lilac.reset! }

  Spec.assert "is-invalid toggles on show_error?" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBContainerClass">
        <form>
          <div data-field="email" id="field-x">
            <input type="text">
          </div>
        </form>
      </div>
    HTML
    Lilac.start
    container = doc.call(:querySelector, "#field-x")
    # Initially: touched=false, so show_error? = false → no is-invalid
    Spec.assert_equal false, container[:classList].call(:contains, "is-invalid").js_bool
    # Simulate touch by dispatching blur on the input
    input = container.call(:querySelector, "input")
    ev = JS.global[:document][:defaultView][:Event]
    input.call(:dispatchEvent, ev.new("blur", JS.object(bubbles: true)))
    # After blur: touched=true and value is empty → show_error? = true → is-invalid
    Spec.assert_equal true, container[:classList].call(:contains, "is-invalid").js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "is-valid toggles on touched && valid?" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBContainerClass">
        <form>
          <div data-field="email" id="field-y">
            <input type="text">
          </div>
        </form>
      </div>
    HTML
    Lilac.start
    container = doc.call(:querySelector, "#field-y")
    input = container.call(:querySelector, "input")
    ev = JS.global[:document][:defaultView][:Event]
    # Type a value (input event) to make it valid, then blur to touch.
    input[:value] = "ok@example.com"
    input.call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    input.call(:dispatchEvent, ev.new("blur", JS.object(bubbles: true)))
    Spec.assert_equal true,  container[:classList].call(:contains, "is-valid").js_bool
    Spec.assert_equal false, container[:classList].call(:contains, "is-invalid").js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "data-field-no-class suppresses container class wiring" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBContainerClass">
        <form>
          <div data-field="email" data-field-no-class id="field-z">
            <input type="text">
          </div>
        </form>
      </div>
    HTML
    Lilac.start
    container = doc.call(:querySelector, "#field-z")
    input = container.call(:querySelector, "input")
    ev = JS.global[:document][:defaultView][:Event]
    input.call(:dispatchEvent, ev.new("blur", JS.object(bubbles: true)))
    # is-invalid would normally be added — but no-class suppresses it.
    Spec.assert_equal false, container[:classList].call(:contains, "is-invalid").js_bool
    body[:innerHTML] = ""
  end

  Spec.assert "data-field-invalid / data-field-valid customize class names" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBContainerClass">
        <form>
          <div data-field="email"
               data-field-invalid="ng"
               data-field-valid="ok"
               id="field-c">
            <input type="text">
          </div>
        </form>
      </div>
    HTML
    Lilac.start
    container = doc.call(:querySelector, "#field-c")
    input = container.call(:querySelector, "input")
    ev = JS.global[:document][:defaultView][:Event]
    input.call(:dispatchEvent, ev.new("blur", JS.object(bubbles: true)))
    Spec.assert_equal true,  container[:classList].call(:contains, "ng").js_bool
    Spec.assert_equal false, container[:classList].call(:contains, "is-invalid").js_bool
    body[:innerHTML] = ""
  end
end

Spec.describe "Scanner: error slot wiring" do
  Spec.after { Lilac.reset! }

  Spec.assert ".error descendant gets error text + hidden toggling" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBErrorSlot">
        <form>
          <div data-field="email" id="es-1">
            <input type="text">
            <p class="error"></p>
          </div>
        </form>
      </div>
    HTML
    Lilac.start
    slot = doc.call(:querySelector, "#es-1 .error")
    input = doc.call(:querySelector, "#es-1 input")
    ev = JS.global[:document][:defaultView][:Event]
    # Initial: error exists ("must include @") but touched=false so hidden.
    Spec.assert_equal true, slot.call(:hasAttribute, "hidden").js_bool
    # Touch via blur — show_error? becomes true → slot text + visible.
    input.call(:dispatchEvent, ev.new("blur", JS.object(bubbles: true)))
    Spec.assert_equal false, slot.call(:hasAttribute, "hidden").js_bool
    Spec.assert_equal "must include @", slot[:textContent].to_s
    body[:innerHTML] = ""
  end

  Spec.assert "[data-field-error] takes priority over .error" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBErrorSlot">
        <form>
          <div data-field="email" id="es-2">
            <input type="text">
            <span data-field-error></span>
            <p class="error"></p>
          </div>
        </form>
      </div>
    HTML
    Lilac.start
    input = doc.call(:querySelector, "#es-2 input")
    ev = JS.global[:document][:defaultView][:Event]
    input.call(:dispatchEvent, ev.new("blur", JS.object(bubbles: true)))
    span = doc.call(:querySelector, "#es-2 [data-field-error]")
    p_el = doc.call(:querySelector, "#es-2 .error")
    # The data-field-error span gets the error, the .error <p> does NOT.
    Spec.assert_equal "must include @", span[:textContent].to_s
    Spec.assert_equal "",                p_el[:textContent].to_s
    body[:innerHTML] = ""
  end

  Spec.assert "no slot present is silent (no crash)" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="FBErrorSlot">
        <form>
          <div data-field="email">
            <input type="text">
          </div>
        </form>
      </div>
    HTML
    Lilac.start   # should not raise
    body[:innerHTML] = ""
  end
end

Spec.describe "Scanner: 2-phase DOM order independence" do
  Spec.after { Lilac.reset! }

  Spec.assert "computed referencing auto-registered field works (lazy Computed + 2-phase)" do
    doc = JS.global[:document]
    body = doc[:body]
    # The computed is created in setup BEFORE the scanner auto-registers
    # :query (Lazy Computed defers eval). data-text dispatch in phase B
    # binds the effect that finally reads @derived.value, by which time
    # phase A has registered the field via auto-register.
    body[:innerHTML] = <<~HTML
      <div data-component="FB2PhaseLazyComputed">
        <form>
          <p id="lazy-out" data-text="@derived"></p>
          <input data-field="query" value="hello">
        </form>
      </div>
    HTML
    Lilac.start
    out = doc.call(:querySelector, "#lazy-out")
    Spec.assert_equal "HELLO", out[:textContent].to_s
    body[:innerHTML] = ""
  end

  Spec.assert "data-button before data-field in DOM still resolves" do
    doc = JS.global[:document]
    body = doc[:body]
    # The <button data-button="save"> appears BEFORE the <input data-field>
    # that would (in DOM-order processing) declare the form scope. With
    # 2-phase processing, both :button and :field dispatches run in phase A
    # so order of their DOM positions doesn't matter for correctness.
    body[:innerHTML] = <<~HTML
      <div data-component="FB2Phase">
        <form>
          <button type="button" data-button="save" id="save-btn">Save</button>
          <input data-field="query" value="hello">
        </form>
      </div>
    HTML
    Lilac.start
    host_el = doc.call(:querySelector, "[data-component='FB2Phase']")
    host = Lilac.find_for_element(host_el)
    btn = doc.call(:querySelector, "#save-btn")
    btn.call(:click)
    Spec.assert_equal true, host.instance_variable_get(:@saved)
    body[:innerHTML] = ""
  end
end
