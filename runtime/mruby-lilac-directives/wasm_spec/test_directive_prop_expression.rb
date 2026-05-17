# Tests for `data-prop-X="<expr>"` — parent → child prop passing where
# the value can be a `@ivar` (parent signal current value) or `it.field`
# (current iteration item). The parent's per-row scanner resolves the
# expression at clone-time and writes the scalar back to the attribute,
# so the child's `Props.build` sees a static literal.

Spec.describe "data-prop-* expression resolution" do
  Spec.assert "it.field is resolved at clone-time inside data-each" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :title, String
      prop :id, Integer
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

    Lilac.register("expr-parent-it", parent_klass)
    Lilac.register("expr-child-it", child_klass)

    body[:innerHTML] = '<div data-component="expr-parent-it"><ul data-each="@items" data-key="id"><li data-component="expr-child-it" data-prop-id="it.id" data-prop-title="it.title"></li></ul></div>'

    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    lis = body.call(:querySelectorAll, "[data-component='expr-child-it']")
    Spec.assert_equal 2, lis[:length].to_i
    c1 = Lilac.find_for_element(lis[0])
    c2 = Lilac.find_for_element(lis[1])
    Spec.assert_equal 1, c1.instance_variable_get(:@id).value
    Spec.assert_equal "alpha", c1.instance_variable_get(:@title).value
    Spec.assert_equal 2, c2.instance_variable_get(:@id).value
    Spec.assert_equal "beta", c2.instance_variable_get(:@title).value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "@ivar resolves from parent's setup-declared signal inside data-each row" do
    # @ivar values in data-prop-* work inside data-each because dispatch_each
    # runs at parent's bind_template_hook (= after parent's setup), so the
    # parent's signal exists when the row is cloned and resolve_props runs.
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :label, String
    end
    parent_klass = Class.new(Lilac::Component) do
      attr_reader :items, :prefix
      define_method(:setup) do
        @prefix = signal("tag")
        @items = signal([{ "id" => 1 }, { "id" => 2 }])
      end
    end

    Lilac.register("expr-parent-ivar-each", parent_klass)
    Lilac.register("expr-child-ivar-each", child_klass)

    body[:innerHTML] = '<div data-component="expr-parent-ivar-each"><ul data-each="@items" data-key="id"><li data-component="expr-child-ivar-each" data-prop-label="@prefix"></li></ul></div>'

    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    children = body.call(:querySelectorAll, "[data-component='expr-child-ivar-each']")
    Spec.assert_equal 2, children[:length].to_i
    c1 = Lilac.find_for_element(children[0])
    Spec.assert_equal "tag", c1.instance_variable_get(:@label).value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "literal value still works (parse failure = passthrough)" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :label, String
    end
    parent_klass = Class.new(Lilac::Component) {}

    Lilac.register("expr-parent-lit", parent_klass)
    Lilac.register("expr-child-lit", child_klass)

    body[:innerHTML] = '<div data-component="expr-parent-lit"><div data-component="expr-child-lit" data-prop-label="static literal"></div></div>'

    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    child = Lilac.find_for_element(body.call(:querySelector, "[data-component='expr-child-lit']"))
    Spec.assert_equal "static literal", child.instance_variable_get(:@label).value

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "Integer prop type coercion applies after expression resolution" do
    body = JS.global[:document][:body]

    child_klass = Class.new(Lilac::Component) do
      prop :n, Integer
    end
    parent_klass = Class.new(Lilac::Component) do
      attr_reader :items
      define_method(:setup) do
        @items = signal([{ "id" => 1, "n" => 42 }])
      end
    end

    Lilac.register("expr-parent-coerce", parent_klass)
    Lilac.register("expr-child-coerce", child_klass)

    body[:innerHTML] = '<div data-component="expr-parent-coerce"><ul data-each="@items" data-key="id"><li data-component="expr-child-coerce" data-prop-n="it.n"></li></ul></div>'

    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    child = Lilac.find_for_element(body.call(:querySelector, "[data-component='expr-child-coerce']"))
    n = child.instance_variable_get(:@n).value
    Spec.assert_equal 42, n
    Spec.assert_true n.is_a?(Integer)

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
