Spec.describe "Lilac::WebStorage" do
  Spec.assert "rejects unknown backend symbol" do
    Spec.assert_raises(ArgumentError) { Lilac::WebStorage.new(:cookie, "k") }
  end

  Spec.assert "rejects empty key" do
    Spec.assert_raises(ArgumentError) { Lilac::WebStorage.new(:localStorage, "") }
  end

  Spec.assert "exposes backend and key" do
    s = Lilac::WebStorage.new(:localStorage, "ws-attr")
    Spec.assert_equal :localStorage, s.backend
    Spec.assert_equal "ws-attr", s.key
  end

  Spec.assert "fetch yields fallback when key is absent" do
    begin
      JS.global[:localStorage].call(:removeItem, "ws-absent")
      s = Lilac::WebStorage.new(:localStorage, "ws-absent")
      Spec.assert_equal :fb, s.fetch { :fb }
    ensure
      JS.global[:localStorage].call(:removeItem, "ws-absent")
    end
  end

  Spec.assert "fetch returns parsed value when present" do
    JS.global[:localStorage].call(:setItem, "ws-present",
                                   Lilac::JSON.generate([1, 2, 3]))
    begin
      s = Lilac::WebStorage.new(:localStorage, "ws-present")
      Spec.assert_equal [1, 2, 3], s.fetch { :unused }
    ensure
      JS.global[:localStorage].call(:removeItem, "ws-present")
    end
  end

  Spec.assert "fetch falls back to block on broken JSON and warns" do
    JS.global[:localStorage].call(:setItem, "ws-broken", "}}}not json")
    captured = []
    Lilac.logger = ->(severity, msg, _err) { captured << [severity, msg] if severity == :warn }

    begin
      s = Lilac::WebStorage.new(:localStorage, "ws-broken")
      Spec.assert_equal :fb, s.fetch { :fb }
      Spec.assert_equal 1, captured.length
      Spec.assert_true captured.first[1].to_s.include?("ws-broken")
      Spec.assert_true captured.first[1].to_s.include?("load failed")
    ensure
      Lilac.logger = nil
      JS.global[:localStorage].call(:removeItem, "ws-broken")
    end
  end

  Spec.assert "fetch requires a block" do
    s = Lilac::WebStorage.new(:localStorage, "ws-noblock")
    Spec.assert_raises(ArgumentError) { s.fetch }
  end

  Spec.assert "write stores JSON-serialized value" do
    JS.global[:localStorage].call(:removeItem, "ws-write")
    begin
      s = Lilac::WebStorage.new(:localStorage, "ws-write")
      s.write({ "name" => "alice", "count" => 7 })

      raw = JS.global[:localStorage].call(:getItem, "ws-write").to_s
      Spec.assert_equal({ "name" => "alice", "count" => 7 }, Lilac::JSON.parse(raw))
    ensure
      JS.global[:localStorage].call(:removeItem, "ws-write")
    end
  end

  Spec.assert "remove clears the entry" do
    JS.global[:localStorage].call(:setItem, "ws-rm", "\"x\"")
    begin
      s = Lilac::WebStorage.new(:localStorage, "ws-rm")
      s.remove
      Spec.assert_true JS.global[:localStorage].call(:getItem, "ws-rm").js_null?
    ensure
      JS.global[:localStorage].call(:removeItem, "ws-rm")
    end
  end

  Spec.assert "sessionStorage backend round-trips" do
    JS.global[:sessionStorage].call(:removeItem, "ws-sess")
    begin
      s = Lilac::WebStorage.new(:sessionStorage, "ws-sess")
      s.write("hi")
      Spec.assert_equal "hi", s.fetch { :unused }
    ensure
      JS.global[:sessionStorage].call(:removeItem, "ws-sess")
    end
  end
end
