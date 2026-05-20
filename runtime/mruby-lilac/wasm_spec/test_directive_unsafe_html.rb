Spec.describe "data-unsafe-html directive (lilac-cli codegen target)" do
  Spec.assert "bind refs.lilN, html: @signal writes innerHTML" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="C"><div data-ref="gH">init</div></div>'

    klass = Class.new(Lilac::Component) do
      attr_reader :content
      define_method(:setup) { @content = signal("<em>hello</em>") }
    end
    bindings = Module.new do
      define_method(:bind_template_hook) { bind refs.gH, html: @content }
    end
    klass.include(bindings)

    Lilac.register("C", klass)
    Lilac.start
    Lilac.flush_async!

    target = body.call(:querySelector, "[data-ref=\"gH\"]")
    Spec.assert_equal "<em>hello</em>", target[:innerHTML].to_s.strip

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"C\"]"))
    inst.content.value = "<strong>updated</strong>"
    Lilac.flush_async!
    Spec.assert_equal "<strong>updated</strong>", target[:innerHTML].to_s.strip

    Lilac.reset!
    body[:innerHTML] = ""
    Lilac.flush_async!
  end
end
