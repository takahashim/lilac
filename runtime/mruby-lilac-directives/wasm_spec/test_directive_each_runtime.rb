Spec.describe "data-each (runtime scanner)" do
  Spec.assert "data-each + data-text='name' renders one row per item, reactively" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="each-rt">
        <ul data-ref="list" data-each="@items" data-key="id">
          <li data-text="name"></li>
        </ul>
      </div>
    HTML

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { id: 1, name: "apple" },
          { id: 2, name: "banana" },
        ])
      end
    end

    Lilac.register("each-rt", klass)
    Lilac.start
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component=\"each-rt\"] li")
    Spec.assert_equal 2, lis[:length].to_i
    Spec.assert_equal "apple",  lis[0][:textContent].to_s
    Spec.assert_equal "banana", lis[1][:textContent].to_s

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"each-rt\"]"))
    inst.items.value = [
      { id: 1, name: "apple" },
      { id: 2, name: "blueberry" },
      { id: 3, name: "cherry" },
    ]
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component=\"each-rt\"] li")
    Spec.assert_equal 3, lis[:length].to_i
    Spec.assert_equal "blueberry", lis[1][:textContent].to_s
    Spec.assert_equal "cherry",    lis[2][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-each row data-on-click receives (item, event) and fires method" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="each-click-rt">
        <ul data-each="@items" data-key="id">
          <li><button data-on-click="pick">go</button></li>
        </ul>
      </div>
    HTML

    klass = Class.new(Lilac::Component) do
      attr_reader :picked, :items
      define_method(:setup) do
        @picked = []
        @items = signal([{ id: 10, name: "x" }, { id: 20, name: "y" }])
      end
      define_method(:pick) { |item, _ev| @picked << item[:id] }
    end

    Lilac.register("each-click-rt", klass)
    Lilac.start
    Lilac.flush_async!

    btns = body.call(:querySelectorAll, "[data-component=\"each-click-rt\"] button")
    btns[1].call(:click)
    btns[0].call(:click)
    Lilac.flush_async!

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"each-click-rt\"]"))
    Spec.assert_equal [20, 10], inst.picked

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-each without data-key falls back to object_id keying" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="each-nokey-rt">
        <ul data-each="@items">
          <li data-text="name"></li>
        </ul>
      </div>
    HTML

    item_a = { id: 1, name: "alpha" }
    item_b = { id: 2, name: "beta" }
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { @items = signal([item_a, item_b]) }
    end

    Lilac.register("each-nokey-rt", klass)
    Lilac.start
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component=\"each-nokey-rt\"] li")
    Spec.assert_equal 2, lis[:length].to_i
    Spec.assert_equal "alpha", lis[0][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "nested data-each: inner `it` shadows outer `it`" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="each-nested-rt">
        <ul data-ref="outer" data-each="@groups" data-key="id">
          <li>
            <span class="g-name" data-text="name"></span>
            <ul data-each="items" data-key="id">
              <li class="g-item" data-text="label"></li>
            </ul>
          </li>
        </ul>
      </div>
    HTML

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @groups = signal([
          { id: 1, name: "Fruit",  items: [{ id: 11, label: "apple" }, { id: 12, label: "pear" }] },
          { id: 2, name: "Drinks", items: [{ id: 21, label: "tea" }] },
        ])
      end
    end

    Lilac.register("each-nested-rt", klass)
    Lilac.start
    Lilac.flush_async!

    names = body.call(:querySelectorAll, "[data-component=\"each-nested-rt\"] .g-name")
    Spec.assert_equal "Fruit",  names[0][:textContent].to_s
    Spec.assert_equal "Drinks", names[1][:textContent].to_s

    items = body.call(:querySelectorAll, "[data-component=\"each-nested-rt\"] .g-item")
    Spec.assert_equal 3, items[:length].to_i
    Spec.assert_equal "apple", items[0][:textContent].to_s
    Spec.assert_equal "pear",  items[1][:textContent].to_s
    Spec.assert_equal "tea",   items[2][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-each on Data-attribute items (bare ident via public_send)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="each-data-rt">
        <ul data-each="@todos" data-key="id">
          <li data-text="title"></li>
        </ul>
      </div>
    HTML

    todo_class = Class.new do
      attr_reader :id, :title
      def initialize(id, title); @id = id; @title = title; end
    end

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @todos = signal([todo_class.new(1, "first"), todo_class.new(2, "second")])
      end
    end

    Lilac.register("each-data-rt", klass)
    Lilac.start
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component=\"each-data-rt\"] li")
    Spec.assert_equal "first",  lis[0][:textContent].to_s
    Spec.assert_equal "second", lis[1][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "data-each row whose item field holds a Signal is reactive (per-row)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = <<~HTML
      <div data-component="each-sig-rt">
        <ul data-each="@rows" data-key="id">
          <li data-class="{ active: active }" data-text="name"></li>
        </ul>
      </div>
    HTML

    a_active = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        a_active = signal(false)
        @rows = signal([
          { id: 1, name: "a", active: a_active },
          { id: 2, name: "b", active: signal(false) },
        ])
      end
    end

    Lilac.register("each-sig-rt", klass)
    Lilac.start
    Lilac.flush_async!

    lis = body.call(:querySelectorAll, "[data-component=\"each-sig-rt\"] li")
    Spec.assert_equal false, lis[0][:classList].call(:contains, "active").js_bool
    Spec.assert_equal false, lis[1][:classList].call(:contains, "active").js_bool

    # Flip only row 1's per-row Signal — no list re-emit. The binding must
    # have subscribed to the inner Signal (regression: it used to bind the
    # always-truthy Signal object, so the class never reflected the value).
    a_active.value = true
    Lilac.flush_async!
    Spec.assert_equal true,  lis[0][:classList].call(:contains, "active").js_bool
    Spec.assert_equal false, lis[1][:classList].call(:contains, "active").js_bool

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
