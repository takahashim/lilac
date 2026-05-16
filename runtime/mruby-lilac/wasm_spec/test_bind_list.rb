Spec.describe "bind_list" do
  Spec.assert "renders initial items as direct children" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-init"><ul data-ref="list"></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Lilac.register "bl-init", klass
    Lilac.start

    list = doc.call(:querySelector, "[data-ref='list']")
    Spec.assert_equal 3, list[:children][:length].to_i
    Spec.assert_equal "a", list[:children][0][:textContent].to_s
    Spec.assert_equal "b", list[:children][1][:textContent].to_s
    Spec.assert_equal "c", list[:children][2][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "appended item adds one DOM node, others preserved" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-append"><ul data-ref="list"></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Lilac.register "bl-append", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='bl-append']")
    inst = Lilac.find_for_element(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_b = list[:children][1]

    inst.items.update { |arr| arr + [{id: 3, t: "c"}] }

    Spec.assert_equal 3, list[:children][:length].to_i
    Spec.assert_true list[:children][0] == node_a
    Spec.assert_true list[:children][1] == node_b
    Spec.assert_equal "c", list[:children][2][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "removed item disposes its node, others preserved" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-remove"><ul data-ref="list"></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Lilac.register "bl-remove", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='bl-remove']")
    inst = Lilac.find_for_element(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_c = list[:children][2]

    # Remove the middle item
    inst.items.update { |arr| arr.reject { |it| it[:id] == 2 } }

    Spec.assert_equal 2, list[:children][:length].to_i
    Spec.assert_true list[:children][0] == node_a
    Spec.assert_true list[:children][1] == node_c

    body[:innerHTML] = ""
  end

  Spec.assert "in-place update replaces only the changed item's node" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-update"><ul data-ref="list"></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Lilac.register "bl-update", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='bl-update']")
    inst = Lilac.find_for_element(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_b = list[:children][1]

    # Update item 2's text
    inst.items.update do |arr|
      arr.map { |it| it[:id] == 2 ? {id: 2, t: "B!"} : it }
    end

    # Item 1's node is the SAME object — content unchanged.
    Spec.assert_true list[:children][0] == node_a
    Spec.assert_equal "a", list[:children][0][:textContent].to_s

    # Item 2's node was replaced — different identity, new content.
    Spec.assert_false list[:children][1] == node_b
    Spec.assert_equal "B!", list[:children][1][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "reordering moves existing nodes without re-creating them" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-reorder"><ul data-ref="list"></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "a"}, {id: 2, t: "b"}, {id: 3, t: "c"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li, it[:t])
        end
      end
    end
    Lilac.register "bl-reorder", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='bl-reorder']")
    inst = Lilac.find_for_element(el)
    list = doc.call(:querySelector, "[data-ref='list']")

    node_a = list[:children][0]
    node_b = list[:children][1]
    node_c = list[:children][2]

    # Reorder: c, a, b
    inst.items.update do |arr|
      [arr[2], arr[0], arr[1]]
    end

    Spec.assert_true list[:children][0] == node_c
    Spec.assert_true list[:children][1] == node_a
    Spec.assert_true list[:children][2] == node_b

    body[:innerHTML] = ""
  end

  Spec.assert "removed item with nested component is auto-unmounted by MO" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-host"><ul data-ref="list"></ul></div>'

    cleaned = []
    leaf_klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        cleanup { cleaned << refs.label.text }
      end
    end
    host_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{id: 1, t: "alpha"}, {id: 2, t: "beta"}])
        bind_list refs.list, @items, key: ->(it) { it[:id] } do |it|
          HTML(:li,
            HTML(:span, it[:t], data_ref: "label"),
            data_component: "bl-leaf")
        end
      end
    end
    Lilac.register "bl-leaf", leaf_klass
    Lilac.register "bl-host", host_klass
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    el = doc.call(:querySelector, "[data-component='bl-host']")
    inst = Lilac.find_for_element(el)

    # Drop the first item; its leaf component should run cleanup.
    inst.items.update { |arr| arr.reject { |it| it[:id] == 1 } }
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    Spec.assert_equal ["alpha"], cleaned

    body[:innerHTML] = ""
  end

  Spec.assert "per-row bind/effect scope is disposed when a keyed row is removed" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <template data-template="bl_scope"><li><span data-ref="label"></span></li></template>
      <div data-component="bl-scope-host"><ul data-ref="list"></ul></div>
    HTML

    cleaned = []
    klass = Class.new(Lilac::Component) do
      attr_reader :items

      define_method(:setup) do
        @items = signal([{ "id" => 1, "label" => "alpha" }, { "id" => 2, "label" => "beta" }])
        bind_list refs.list, @items, key: "id", template: "bl_scope" do |it, t|
          t.refs.label.text = it["label"]
          cleanup { cleaned << it["id"] }
        end
      end
    end
    Lilac.register "bl-scope-host", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='bl-scope-host']")
    inst = Lilac.find_for_element(el)
    inst.items.update { |arr| arr.reject { |it| it["id"] == 1 } }

    Spec.assert_equal [1], cleaned
    body[:innerHTML] = ""
  end

  Spec.assert "duplicate keys raise Lilac::Error in dev mode" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-dup"><ul data-ref="list"></ul></div>'

    captured = []
    Lilac.logger = ->(_severity, _label, err) { captured << err }
    begin
      klass = Class.new(Lilac::Component) do
        define_method(:setup) do
          items = signal([{"id" => 1, "t" => "a"}, {"id" => 1, "t" => "b"}])
          bind_list refs.list, items, key: "id" do |it|
            HTML(:li, it["t"])
          end
        end
      end
      Lilac.register "bl-dup", klass
      Lilac.start
    ensure
      Lilac.logger = nil
    end

    Spec.assert_equal 1, captured.length
    err = captured.first
    Spec.assert_true err.is_a?(Lilac::Error)
    Spec.assert_true err.message.include?("duplicate keys")
    body[:innerHTML] = ""
  end

  Spec.assert "key: \"id\" String shortcut works against String-keyed Hashes" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-strkey"><ul data-ref="list"></ul></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{"id" => 1, "t" => "a"}, {"id" => 2, "t" => "b"}])
        bind_list refs.list, @items, key: "id" do |it|
          HTML(:li, it["t"])
        end
      end
    end
    Lilac.register "bl-strkey", klass
    Lilac.start

    list = doc.call(:querySelector, "[data-ref='list']")
    Spec.assert_equal 2, list[:children][:length].to_i
    Spec.assert_equal "a", list[:children][0][:textContent].to_s

    body[:innerHTML] = ""
  end

  Spec.assert "key: :id Symbol raises ArgumentError with helpful hint" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-symkey"><ul data-ref="list"></ul></div>'

    captured = []
    Lilac.logger = ->(_severity, _label, err) { captured << err }

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        items = signal([{"id" => 1}])
        bind_list refs.list, items, key: :id do |it|
          HTML(:li, it["id"].to_s)
        end
      end
    end
    Lilac.register "bl-symkey", klass
    Lilac.start

    Spec.assert_equal 1, captured.length
    err = captured.first
    Spec.assert_true err.is_a?(ArgumentError)
    Spec.assert_true err.message.include?("Symbol")
    Spec.assert_true err.message.include?("\"id\"")

    Lilac.logger = nil
    body[:innerHTML] = ""
  end

  Spec.assert "key: 42 (non-Proc/non-String) raises ArgumentError" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="bl-intkey"><ul data-ref="list"></ul></div>'

    captured = []
    Lilac.logger = ->(_severity, _label, err) { captured << err }

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        items = signal([{"id" => 1}])
        bind_list refs.list, items, key: 42 do |it|
          HTML(:li, "x")
        end
      end
    end
    Lilac.register "bl-intkey", klass
    Lilac.start

    Spec.assert_equal 1, captured.length
    Spec.assert_true captured.first.is_a?(ArgumentError)

    Lilac.logger = nil
    body[:innerHTML] = ""
  end
end
