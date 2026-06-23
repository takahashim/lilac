Spec.describe "RefElement#toggle_class" do
  Spec.after { Lilac.reset! }

  def self.mount_box
    doc = JS.global[:document]
    doc[:body][:innerHTML] = '<div data-component="tc"><div data-ref="box"></div></div>'
    inst = nil
    k = Class.new(Lilac::Component) { define_method(:setup) {} }
    Lilac.register "tc", k
    Lilac.start
    Lilac.find_for_element(doc.call(:querySelector, "[data-component='tc']"))
  end

  def self.has_class?(ref, name)
    ref.js[:classList].call(:contains, name).js_bool
  end

  Spec.assert "force omitted flips the class on and off" do
    inst = mount_box
    box = inst.refs.box

    box.toggle_class("show")
    Spec.assert_true has_class?(box, "show")
    box.toggle_class("show")
    Spec.assert_false has_class?(box, "show")
  end

  Spec.assert "force adds (truthy) / removes (falsy) unconditionally" do
    inst = mount_box
    box = inst.refs.box

    box.toggle_class("open", true)
    Spec.assert_true has_class?(box, "open")
    box.toggle_class("open", true)        # still present (not flipped off)
    Spec.assert_true has_class?(box, "open")
    box.toggle_class("open", false)
    Spec.assert_false has_class?(box, "open")
    box.toggle_class("open", nil)         # falsy → stays removed
    Spec.assert_false has_class?(box, "open")
  end
end
