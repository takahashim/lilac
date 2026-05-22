Spec.describe "Component#session_signal" do
  Spec.assert "loads default when sessionStorage is empty" do
    JS.global[:sessionStorage].call(:removeItem, "ss-empty")

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = session_signal("ss-empty", default: "hello")
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    begin
      body[:innerHTML] = '<div data-component="ss-empty"></div>'
      Lilac.register "ss-empty", klass
      Lilac.start

      el = doc.call(:querySelector, "[data-component='ss-empty']")
      Spec.assert_equal "hello", Lilac.find_for_element(el).read
    ensure
      body[:innerHTML] = ""
      Lilac.flush_async!
      JS.global[:sessionStorage].call(:removeItem, "ss-empty")
    end
  end

  Spec.assert "restores stored value from sessionStorage" do
    JS.global[:sessionStorage].call(:setItem, "ss-stored",
      Lilac::JSON.generate({ "draft" => "in progress" }))

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = session_signal("ss-stored") { {} }
      end
      define_method(:read) { @s.value }
    end

    doc = JS.global[:document]
    body = doc[:body]
    begin
      body[:innerHTML] = '<div data-component="ss-stored"></div>'
      Lilac.register "ss-stored", klass
      Lilac.start

      el = doc.call(:querySelector, "[data-component='ss-stored']")
      Spec.assert_equal({ "draft" => "in progress" }, Lilac.find_for_element(el).read)
    ensure
      body[:innerHTML] = ""
      Lilac.flush_async!
      JS.global[:sessionStorage].call(:removeItem, "ss-stored")
    end
  end

  Spec.assert "writes to sessionStorage when signal changes" do
    JS.global[:sessionStorage].call(:removeItem, "ss-write")

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = session_signal("ss-write", default: 0)
      end
      define_method(:bump) { @s.update { |n| n + 1 } }
    end

    doc = JS.global[:document]
    body = doc[:body]
    begin
      body[:innerHTML] = '<div data-component="ss-write"></div>'
      Lilac.register "ss-write", klass
      Lilac.start

      el = doc.call(:querySelector, "[data-component='ss-write']")
      inst = Lilac.find_for_element(el)

      # Initial effect run wrote the default.
      raw = JS.global[:sessionStorage].call(:getItem, "ss-write").to_s
      Spec.assert_equal "0", raw

      inst.bump
      raw2 = JS.global[:sessionStorage].call(:getItem, "ss-write").to_s
      Spec.assert_equal "1", raw2
    ensure
      body[:innerHTML] = ""
      Lilac.flush_async!
      JS.global[:sessionStorage].call(:removeItem, "ss-write")
    end
  end

  Spec.assert "uses sessionStorage, not localStorage" do
    # Cross-check: writing to session_signal must not leak into
    # localStorage with the same key.
    JS.global[:localStorage].call(:removeItem, "ss-isolation")
    JS.global[:sessionStorage].call(:removeItem, "ss-isolation")

    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        @s = session_signal("ss-isolation", default: "tab-only")
      end
    end

    doc = JS.global[:document]
    body = doc[:body]
    begin
      body[:innerHTML] = '<div data-component="ss-isolation"></div>'
      Lilac.register "ss-isolation", klass
      Lilac.start

      Spec.assert_true JS.global[:localStorage].call(:getItem, "ss-isolation").js_null?
      session_value = JS.global[:sessionStorage].call(:getItem, "ss-isolation")
      Spec.assert_false session_value.js_null?
    ensure
      body[:innerHTML] = ""
      Lilac.flush_async!
      JS.global[:localStorage].call(:removeItem, "ss-isolation")
      JS.global[:sessionStorage].call(:removeItem, "ss-isolation")
    end
  end
end
