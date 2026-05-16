Spec.describe "Lilac::JSON" do
  Spec.assert "generate serializes scalars, arrays, and nested hashes" do
    Spec.assert_equal "0",     Lilac::JSON.generate(0)
    Spec.assert_equal "\"hi\"", Lilac::JSON.generate("hi")
    Spec.assert_equal "true",  Lilac::JSON.generate(true)
    Spec.assert_equal "null",  Lilac::JSON.generate(nil)
    Spec.assert_equal "[1,2,3]", Lilac::JSON.generate([1, 2, 3])
    Spec.assert_equal '{"a":1,"b":2}', Lilac::JSON.generate({ "a" => 1, "b" => 2 })
  end

  Spec.assert "generate handles Array<Hash> (regression: JS.object would garble)" do
    cards = [
      { "id" => 1, "title" => "first" },
      { "id" => 2, "title" => "second" },
    ]
    json = Lilac::JSON.generate(cards)
    # round-trip through parse to confirm structure
    Spec.assert_equal cards, Lilac::JSON.parse(json)
  end

  Spec.assert "parse returns Ruby values (recursively to_ruby'd)" do
    Spec.assert_equal [1, 2, 3], Lilac::JSON.parse("[1,2,3]")
    Spec.assert_equal({ "a" => 1, "b" => "two" },
      Lilac::JSON.parse('{"a":1,"b":"two"}'))
    Spec.assert_equal [{ "id" => 9 }, { "id" => 10 }],
      Lilac::JSON.parse('[{"id":9},{"id":10}]')
  end

  Spec.assert "parse on invalid JSON raises JS::Error" do
    raised = false
    begin
      Lilac::JSON.parse("}}}not json")
    rescue JS::Error
      raised = true
    end
    Spec.assert_true raised
  end
end
