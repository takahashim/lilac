Spec.describe "data-autofocus (runtime scanner)" do
  Spec.assert "focuses the element on mount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] =
      '<div data-component="af-rt"><input data-autofocus></div>'

    klass = Class.new(Lilac::Component) do
      define_method(:setup) { }
    end

    Lilac.register("af-rt", klass)
    Lilac.start
    Lilac.flush_async!

    input = body.call(:querySelector, "input")
    active = doc[:activeElement]
    Spec.assert_true active == input,
                     "expected input to be document.activeElement"

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
