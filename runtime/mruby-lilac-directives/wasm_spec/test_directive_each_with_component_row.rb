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

    # Directives on a row COMPONENT's root bind in the CHILD's scope
    # (same as codegen). Per ADR-0016 a bare ident in a directive value
    # means "iteration item field" — which only exists in the parent
    # scope — so on a component row root you reference the prop's ivar
    # (`@id`), not bare `id`. `prop :id` creates that `@id` Signal
    # (auto-filled from the item).
    item_klass = Class.new(Lilac::Component) do
      prop :id, Integer
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

    body[:innerHTML] = '<div data-component="reorder-list"><ul data-each="@items" data-key="id"><li data-component="reorder-item" data-attr-data-id="@id"><span class="t" data-text="@title"></span></li></ul></div>'

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

  Spec.assert "row-component ROOT directive referencing a setup-created ivar binds in the child scope" do
    # Regression (7guis CRUD): the data-each row is itself a
    # data-component, and the directive lives on the row's ROOT element
    # referencing an ivar the row's own `setup` creates (`@is_selected`
    # = computed). The binding must run in the CHILD component's scope,
    # not the parent/iteration scope (where the ivar is nil). Codegen
    # masked this by generating the child's bindings separately; the
    # scanner path must defer the row-root's directives to the child.
    body = JS.global[:document][:body]

    item_klass = Class.new(Lilac::Component) do
      prop :id, Integer
      define_method(:setup) do
        sel = lookup(:selected_id)
        @is_selected = computed { sel.value == id }
      end
    end
    list_klass = Class.new(Lilac::Component) do
      attr_reader :items, :selected_id
      define_method(:prepare_setup) do
        @items = signal([{ "id" => 1 }, { "id" => 2 }])
        @selected_id = signal(2)
        expose :selected_id, @selected_id
      end
      define_method(:setup) {}
    end

    Lilac.register("sel-list", list_klass)
    Lilac.register("sel-item", item_klass)

    body[:innerHTML] = '<div data-component="sel-list"><ul data-each="@items" data-key="id"><li data-component="sel-item" data-class="{ on: @is_selected }"></li></ul></div>'

    Lilac.start
    Lilac.flush_async!

    rows = body.call(:querySelectorAll, "[data-component='sel-item']")
    Spec.assert_equal 2, rows[:length].to_i
    # id=2 is the selected one → it carries the `on` class; id=1 doesn't.
    Spec.assert_false rows[0][:className].to_s.include?("on")
    Spec.assert_true  rows[1][:className].to_s.include?("on")

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
