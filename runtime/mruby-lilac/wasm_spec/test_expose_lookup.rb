Spec.describe "expose / lookup" do
  Spec.assert "child looks up an ancestor's exposed value" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="pi-app">
        <div data-component="pi-leaf">
          <span data-ref="label">x</span>
        </div>
      </div>
    HTML

    parent_klass = Class.new(Lilac::Component) do
      attr_reader :theme
      define_method(:prepare_setup) do
        @theme = signal("light")
        expose :theme, @theme
      end
    end
    leaf_klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        theme = lookup(:theme)
        bind refs.label, :text do
          theme.value
        end
      end
    end

    Lilac.register "pi-app", parent_klass
    Lilac.register "pi-leaf", leaf_klass
    Lilac.start

    label = doc.call(:querySelector, "[data-ref='label']")
    Spec.assert_equal "light", label[:textContent].to_s

    # Mutating the exposed signal updates the descendant via lookup
    parent_el = doc.call(:querySelector, "[data-component='pi-app']")
    parent_inst = Lilac.find_for_element(parent_el)
    parent_inst.theme.value = "dark"
    Spec.assert_equal "dark", label[:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "intermediate ancestor's expose overrides outer one" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="pi-outer">
        <div data-component="pi-inner">
          <div data-component="pi-grand">
            <span data-ref="out"></span>
          </div>
        </div>
      </div>
    HTML

    outer_klass = Class.new(Lilac::Component) do
      define_method(:prepare_setup) { expose :name, "outer" }
    end
    inner_klass = Class.new(Lilac::Component) do
      define_method(:prepare_setup) { expose :name, "inner" }
    end
    grand_klass = Class.new(Lilac::Component) do
      attr_reader :seen
      define_method(:setup) { @seen = lookup(:name) }
    end

    Lilac.register "pi-outer", outer_klass
    Lilac.register "pi-inner", inner_klass
    Lilac.register "pi-grand", grand_klass
    Lilac.start

    grand_el = doc.call(:querySelector, "[data-component='pi-grand']")
    grand_inst = Lilac.find_for_element(grand_el)
    Spec.assert_equal "inner", grand_inst.seen

    body[:innerHTML] = ""
  end

  Spec.assert "lookup without an exposed value raises with a helpful message" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="pi-orphan"><span data-ref="x"></span></div>'

    captured = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        begin
          lookup(:missing)
        rescue Lilac::Error => e
          @err = e.message
        end
      end
      define_method(:err) { @err }
    end
    Lilac.register "pi-orphan", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='pi-orphan']")
    inst = Lilac.find_for_element(el)
    Spec.assert_true inst.err.include?("missing")
    Spec.assert_true inst.err.include?("lookup")

    body[:innerHTML] = ""
  end

  Spec.assert "lookup(:key, default) returns the default if not exposed" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="pi-default"></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :v
      define_method(:setup) { @v = lookup(:flag, "fallback") }
    end
    Lilac.register "pi-default", klass
    Lilac.start

    inst = Lilac.find_for_element(
      doc.call(:querySelector, "[data-component='pi-default']"))
    Spec.assert_equal "fallback", inst.v

    body[:innerHTML] = ""
  end

  Spec.assert "lookup with block uses block as lazy default" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="pi-block"></div>'

    factory_calls = 0
    klass = Class.new(Lilac::Component) do
      attr_reader :v
      define_method(:setup) do
        @v = lookup(:thing) do
          factory_calls += 1
          "made-fresh"
        end
      end
    end
    Lilac.register "pi-block", klass
    Lilac.start

    inst = Lilac.find_for_element(
      doc.call(:querySelector, "[data-component='pi-block']"))
    Spec.assert_equal "made-fresh", inst.v
    Spec.assert_equal 1, factory_calls

    body[:innerHTML] = ""
  end

  Spec.assert "prepare_setup runs pre-order before any descendant setup" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <div data-component="pi-order-parent">
        <div data-component="pi-order-child">
          <div data-component="pi-order-grand"></div>
        </div>
      </div>
    HTML

    log = []
    parent_klass = Class.new(Lilac::Component) do
      define_method(:prepare_setup) { log << :parent_prepare_setup }
      define_method(:setup)        { log << :parent_setup }
    end
    child_klass = Class.new(Lilac::Component) do
      define_method(:prepare_setup) { log << :child_prepare_setup }
      define_method(:setup)        { log << :child_setup }
    end
    grand_klass = Class.new(Lilac::Component) do
      define_method(:prepare_setup) { log << :grand_prepare_setup }
      define_method(:setup)        { log << :grand_setup }
    end

    Lilac.register "pi-order-parent", parent_klass
    Lilac.register "pi-order-child",  child_klass
    Lilac.register "pi-order-grand",  grand_klass
    Lilac.start

    Spec.assert_equal(
      [:parent_prepare_setup, :child_prepare_setup, :grand_prepare_setup,
       :grand_setup,        :child_setup,        :parent_setup],
      log
    )

    body[:innerHTML] = ""
  end

  Spec.assert "dynamic mount via MO runs prepare_setup for the new subtree" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="pi-dyn-host"><div id="slot"></div></div>'

    host_klass = Class.new(Lilac::Component) do
      define_method(:prepare_setup) { expose :token, "host-token" }
    end
    captured = nil
    inserted_klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        captured = lookup(:token)
      end
    end

    Lilac.register "pi-dyn-host", host_klass
    Lilac.register "pi-dyn-inserted", inserted_klass
    Lilac.start

    slot = doc.call(:querySelector, "#slot")
    new_el = doc.call(:createElement, "div")
    new_el.call(:setAttribute, "data-component", "pi-dyn-inserted")
    slot.call(:appendChild, new_el)
    Lilac.flush_async!

    Spec.assert_equal "host-token", captured

    body[:innerHTML] = ""
  end
end
