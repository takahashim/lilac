Spec.describe "bare ident value (data-each scope)" do
  Spec.assert "data-text='name' inside data-each reads item field" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="bare-text-rt">' \
      '<ul><li data-each="@tags" data-key="id">' \
      '<span data-text="name"></span>' \
      '</li></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :tags
      define_method(:setup) do
        @tags = signal([
          { "id" => 1, "name" => "red" },
          { "id" => 2, "name" => "blue" },
        ])
      end
    end

    Lilac.register("bare-text-rt", klass)
    Lilac.start
    Lilac.flush_async!

    spans = body.call(:querySelectorAll, "span")
    Spec.assert_equal 2, spans[:length].to_i
    Spec.assert_equal "red", spans[0][:textContent].to_s
    Spec.assert_equal "blue", spans[1][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-bind='field' two-way binds to row's nested Signal" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="bare-bind-rt">' \
      '<ul><li data-each="@items" data-key="id">' \
      '<input data-bind="name" type="text">' \
      '</li></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { "id" => 1, "name" => signal("alpha") },
          { "id" => 2, "name" => signal("beta") },
        ])
      end
    end

    Lilac.register("bare-bind-rt", klass)
    Lilac.start
    Lilac.flush_async!

    inputs = body.call(:querySelectorAll, "input")
    Spec.assert_equal "alpha", inputs[0][:value].to_s
    Spec.assert_equal "beta",  inputs[1][:value].to_s

    inst = Lilac.find_for_element(
      body.call(:querySelector, "[data-component='bare-bind-rt']"))
    inst.items.value[0]["name"].value = "gamma"
    Lilac.flush_async!
    Spec.assert_equal "gamma", inputs[0][:value].to_s

    ev = JS.global[:document][:defaultView][:Event]
    inputs[1][:value] = "delta"
    inputs[1].call(:dispatchEvent, ev.new("input", JS.object(bubbles: true)))
    Lilac.flush_async!
    Spec.assert_equal "delta", inst.items.value[1]["name"].value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "child component inside data-each auto-fills props from item" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :id, Integer
      prop :title, String
    end
    parent_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { "id" => 1, "title" => "alpha" },
          { "id" => 2, "title" => "beta" },
        ])
      end
    end

    Lilac.register("autofill-parent", parent_klass)
    Lilac.register("autofill-child", child_klass)

    body[:innerHTML] = '<div data-component="autofill-parent">' \
      '<ul data-each="@items" data-key="id">' \
      '<li data-component="autofill-child"></li>' \
      '</ul></div>'

    Lilac.start
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component='autofill-child']")
    Spec.assert_equal 2, lis[:length].to_i
    c1 = Lilac.find_for_element(lis[0])
    c2 = Lilac.find_for_element(lis[1])
    Spec.assert_equal 1, c1.instance_variable_get(:@id).value
    Spec.assert_equal "alpha", c1.instance_variable_get(:@title).value
    Spec.assert_equal 2, c2.instance_variable_get(:@id).value
    Spec.assert_equal "beta", c2.instance_variable_get(:@title).value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "explicit data-prop-X overrides auto-fill" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :id, Integer
      prop :label, String
    end
    parent_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{ "id" => 1, "label" => "from-item" }])
      end
    end

    Lilac.register("autofill-override-parent", parent_klass)
    Lilac.register("autofill-override-child", child_klass)

    body[:innerHTML] = '<div data-component="autofill-override-parent">' \
      '<ul data-each="@items" data-key="id">' \
      '<li data-component="autofill-override-child" data-prop-label="forced"></li>' \
      '</ul></div>'

    Lilac.start
    Lilac.flush_async!

    li = body.call(:querySelector, "[data-component='autofill-override-child']")
    inst = Lilac.find_for_element(li)
    Spec.assert_equal 1, inst.instance_variable_get(:@id).value
    Spec.assert_equal "forced", inst.instance_variable_get(:@label).value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "auto-filled props update on row reuse" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :id, Integer
      prop :title, String
    end
    parent_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { "id" => 1, "title" => "alpha" },
          { "id" => 2, "title" => "beta" },
        ])
      end
    end

    Lilac.register("autofill-reuse-parent", parent_klass)
    Lilac.register("autofill-reuse-child", child_klass)

    body[:innerHTML] = '<div data-component="autofill-reuse-parent">' \
      '<ul data-each="@items" data-key="id">' \
      '<li data-component="autofill-reuse-child"></li>' \
      '</ul></div>'

    Lilac.start
    Lilac.flush_async!

    parent = Lilac.find_for_element(
      body.call(:querySelector, "[data-component='autofill-reuse-parent']"))
    parent.items.value = [
      { "id" => 1, "title" => "alpha-updated" },
      { "id" => 2, "title" => "beta-updated" },
    ]
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component='autofill-reuse-child']")
    c1 = Lilac.find_for_element(lis[0])
    c2 = Lilac.find_for_element(lis[1])
    Spec.assert_equal "alpha-updated", c1.instance_variable_get(:@title).value
    Spec.assert_equal "beta-updated", c2.instance_variable_get(:@title).value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-prop-X='todo' (bare) is treated as literal, not auto-fill" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :status, String
    end
    parent_klass = Class.new(Lilac::Component) {}

    Lilac.register("literal-parent", parent_klass)
    Lilac.register("literal-child", child_klass)

    body[:innerHTML] = '<div data-component="literal-parent">' \
      '<div data-component="literal-child" data-prop-status="todo"></div></div>'

    Lilac.start
    Lilac.flush_async!

    inst = Lilac.find_for_element(
      body.call(:querySelector, "[data-component='literal-child']"))
    Spec.assert_equal "todo", inst.instance_variable_get(:@status).value

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "bare ident outside data-each in value-binding silent-skips" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="bare-scope-rt">' \
      '<span data-text="name">initial</span></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) {}
    end

    Lilac.register("bare-scope-rt", klass)
    Lilac.start
    Lilac.flush_async!

    span = body.call(:querySelector, "span")
    # No item context → silent skip → original text stays.
    Spec.assert_equal "initial", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

end
