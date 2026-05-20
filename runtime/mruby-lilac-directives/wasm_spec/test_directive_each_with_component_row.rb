# Tests for the "data-each row that is itself a data-component" pattern.
# This is the declarative form unlocked by `prop` auto-init + `data-prop-*`
# expression resolution.

Spec.describe "data-each row that is itself a data-component" do
  Spec.assert "child's data-text='@prop' renders prop value from parent's iteration" do
    body = JS.global[:document][:body]

    item_klass = Class.new(Lilac::Component) do
      prop :title, String
    end
    list_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { "id" => 1, "title" => "first" },
          { "id" => 2, "title" => "second" },
        ])
      end
    end

    Lilac.register("each-cmp-list", list_klass)
    Lilac.register("each-cmp-item", item_klass)

    body[:innerHTML] = '<div data-component="each-cmp-list"><ul data-each="@items" data-key="id"><li data-component="each-cmp-item"><span class="t" data-text="@title"></span></li></ul></div>'

    Lilac.start
    Lilac.flush_async!

    spans = body.call(:querySelectorAll, ".t")
    Spec.assert_equal 2, spans[:length].to_i
    Spec.assert_equal "first",  spans[0][:textContent].to_s
    Spec.assert_equal "second", spans[1][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "row reuse with changed item value updates child's prop signal" do
    body = JS.global[:document][:body]

    item_klass = Class.new(Lilac::Component) do
      prop :title, String
    end
    list_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{ "id" => 1, "title" => "before" }])
      end
    end

    Lilac.register("reuse-list", list_klass)
    Lilac.register("reuse-item", item_klass)

    body[:innerHTML] = '<div data-component="reuse-list"><ul data-each="@items" data-key="id"><li data-component="reuse-item"><span class="t" data-text="@title"></span></li></ul></div>'

    Lilac.start
    Lilac.flush_async!

    span = body.call(:querySelector, ".t")
    Spec.assert_equal "before", span[:textContent].to_s

    # Same key (1), changed title — bind_list reuses the existing row.
    list_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component='reuse-list']"))
    list_inst.items.value = [{ "id" => 1, "title" => "after" }]
    Lilac.flush_async!

    Spec.assert_equal "after", span[:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "child's data-on-X dispatches to child component's method" do
    body = JS.global[:document][:body]

    item_klass = Class.new(Lilac::Component) do
      attr_accessor :clicked
      prop :title, String
      define_method(:setup) { @clicked = false }
      define_method(:click_me) { |_ev| @clicked = true }
    end
    list_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{ "id" => 1, "title" => "one" }])
      end
    end

    Lilac.register("dispatch-list", list_klass)
    Lilac.register("dispatch-item", item_klass)

    body[:innerHTML] = '<div data-component="dispatch-list"><ul data-each="@items" data-key="id"><li data-component="dispatch-item"><button data-on-click="click_me">x</button></li></ul></div>'

    Lilac.start
    Lilac.flush_async!

    btn = body.call(:querySelector, "button")
    btn.call(:click)
    Lilac.flush_async!

    item = Lilac.find_for_element(body.call(:querySelector, "[data-component='dispatch-item']"))
    Spec.assert_true item.clicked

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "reorder (same keys, different order) keeps child components alive with correct props" do
    body = JS.global[:document][:body]

    item_klass = Class.new(Lilac::Component) do
      prop :title, String
    end
    list_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { "id" => 1, "title" => "a" },
          { "id" => 2, "title" => "b" },
        ])
      end
    end

    Lilac.register("reorder-list", list_klass)
    Lilac.register("reorder-item", item_klass)

    body[:innerHTML] = '<div data-component="reorder-list"><ul data-each="@items" data-key="id"><li data-component="reorder-item" data-attr-data-id="id"><span class="t" data-text="@title"></span></li></ul></div>'

    Lilac.start
    Lilac.flush_async!

    items_before = body.call(:querySelectorAll, "[data-component='reorder-item']")
    Spec.assert_equal 2, items_before[:length].to_i
    first_id = items_before[0].call(:getAttribute, "data-id").to_s
    second_id = items_before[1].call(:getAttribute, "data-id").to_s
    Spec.assert_equal "1", first_id
    Spec.assert_equal "2", second_id

    # Reorder (swap)
    list_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component='reorder-list']"))
    list_inst.items.value = [
      { "id" => 2, "title" => "b" },
      { "id" => 1, "title" => "a" },
    ]
    Lilac.flush_async!

    items_after = body.call(:querySelectorAll, "[data-component='reorder-item']")
    Spec.assert_equal 2, items_after[:length].to_i
    Spec.assert_equal "2", items_after[0].call(:getAttribute, "data-id").to_s
    Spec.assert_equal "1", items_after[1].call(:getAttribute, "data-id").to_s

    spans = body.call(:querySelectorAll, ".t")
    Spec.assert_equal "b", spans[0][:textContent].to_s
    Spec.assert_equal "a", spans[1][:textContent].to_s

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "row removal unmounts the child component" do
    body = JS.global[:document][:body]

    unmount_count = 0
    item_klass = Class.new(Lilac::Component) do
      prop :title, String
    end
    item_klass.define_method(:unmount) do
      unmount_count += 1
      super()
    end
    list_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([
          { "id" => 1, "title" => "keep" },
          { "id" => 2, "title" => "remove" },
        ])
      end
    end

    Lilac.register("rm-list", list_klass)
    Lilac.register("rm-item", item_klass)

    body[:innerHTML] = '<div data-component="rm-list"><ul data-each="@items" data-key="id"><li data-component="rm-item"></li></ul></div>'

    Lilac.start
    Lilac.flush_async!
    Spec.assert_equal 2, body.call(:querySelectorAll, "[data-component='rm-item']")[:length].to_i

    list_inst = Lilac.find_for_element(body.call(:querySelector, "[data-component='rm-list']"))
    list_inst.items.value = [{ "id" => 1, "title" => "keep" }]
    Lilac.flush_async!

    Spec.assert_equal 1, body.call(:querySelectorAll, "[data-component='rm-item']")[:length].to_i
    Spec.assert_true unmount_count >= 1

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
