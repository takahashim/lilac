Spec.describe "Component#persistent_signal" do
  Spec.assert "loads default (block form) when localStorage is empty" do
    JS.global[:localStorage].call(:removeItem, "ps-empty-block")

    captured = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = persistent_signal("ps-empty-block") { [1, 2, 3] }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ps-empty-block"></div>'
    Lilac.register "ps-empty-block", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='ps-empty-block']")
    captured = Lilac.find_for_element(el).read
    Spec.assert_equal [1, 2, 3], captured

    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "loads default (kwarg form) when localStorage is empty" do
    JS.global[:localStorage].call(:removeItem, "ps-empty-kwarg")

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = persistent_signal("ps-empty-kwarg", default: "hello")
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ps-empty-kwarg"></div>'
    Lilac.register "ps-empty-kwarg", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='ps-empty-kwarg']")
    Spec.assert_equal "hello", Lilac.find_for_element(el).read

    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "restores stored value from localStorage" do
    JS.global[:localStorage].call(:setItem, "ps-stored",
      Lilac::JSON.generate([{ "id" => 9, "title" => "x" }]))

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = persistent_signal("ps-stored") { [] }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ps-stored"></div>'
    Lilac.register "ps-stored", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='ps-stored']")
    Spec.assert_equal [{ "id" => 9, "title" => "x" }], Lilac.find_for_element(el).read

    JS.global[:localStorage].call(:removeItem, "ps-stored")
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "broken JSON falls back to default and warns" do
    JS.global[:localStorage].call(:setItem, "ps-broken", "}}}not json")

    captured = []
    Lilac.logger = ->(severity, msg, _err) { captured << [severity, msg] if severity == :warn }

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = persistent_signal("ps-broken") { "fallback" }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ps-broken"></div>'
    Lilac.register "ps-broken", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='ps-broken']")
    Spec.assert_equal "fallback", Lilac.find_for_element(el).read
    Spec.assert_equal 1, captured.length
    Spec.assert_true captured.first[1].to_s.include?("ps-broken")

    Lilac.logger = nil
    JS.global[:localStorage].call(:removeItem, "ps-broken")
    body[:innerHTML] = ""
    Lilac.flush_async!
  end

  Spec.assert "writes to localStorage when signal changes" do
    JS.global[:localStorage].call(:removeItem, "ps-write")

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = persistent_signal("ps-write", default: 0)
      end
      define_method(:bump) { @s.update { |n| n + 5 } }
    end

    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="ps-write"></div>'
    Lilac.register "ps-write", klass
    Lilac.start

    el = doc.call(:querySelector, "[data-component='ps-write']")
    inst = Lilac.find_for_element(el)

    # Initial effect run already wrote default.
    raw = JS.global[:localStorage].call(:getItem, "ps-write").to_s
    Spec.assert_equal "0", raw

    inst.bump
    raw2 = JS.global[:localStorage].call(:getItem, "ps-write").to_s
    Spec.assert_equal "5", raw2

    JS.global[:localStorage].call(:removeItem, "ps-write")
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
