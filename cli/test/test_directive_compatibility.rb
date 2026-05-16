# frozen_string_literal: true

require "test_helper"

class TestDirectiveCompatibility < Minitest::Test
  DC = Grainet::CLI::DirectiveCompatibility

  def dir(kind, ref_id: "g0", line: 1, tag: "div", value: "@x", name: nil, scope_id: nil)
    Grainet::CLI::Directive.new(
      kind: kind, name: name, value: value, ref_id: ref_id,
      line: line, element_tag: tag, scope_id: scope_id,
    )
  end

  # ---- collision pairs --------------------------------------------

  def test_text_and_unsafe_html_on_same_element_raise
    err = assert_raises(DC::Error) do
      DC.check!([dir(:text), dir(:unsafe_html, line: 2)], file: "x.gnt")
    end
    assert_includes err.message, "x.gnt:2"
    assert_includes err.message, "data-text and data-unsafe-html"
  end

  def test_text_and_each_on_same_element_raise
    err = assert_raises(DC::Error) do
      DC.check!([dir(:text, tag: "ul"), dir(:each, tag: "ul", value: "@items")], file: "x.gnt")
    end
    assert_includes err.message, "data-text and data-each"
  end

  def test_show_and_hide_on_same_element_raise
    err = assert_raises(DC::Error) do
      DC.check!([dir(:show), dir(:hide, line: 3)], file: "x.gnt")
    end
    assert_includes err.message, "x.gnt:3"
    assert_includes err.message, "data-show and data-hide"
  end

  def test_value_and_checked_on_same_element_raise
    err = assert_raises(DC::Error) do
      DC.check!([dir(:value, tag: "input"), dir(:checked, tag: "input", line: 4)], file: "x.gnt")
    end
    assert_includes err.message, "data-value and data-checked"
  end

  def test_component_and_each_on_same_element_raise
    err = assert_raises(DC::Error) do
      DC.check!(
        [
          dir(:component, value: "X", tag: "ul"),
          dir(:each, value: "@items", tag: "ul", line: 6),
        ],
        file: "x.gnt",
      )
    end
    assert_includes err.message, "x.gnt:6"
    assert_includes err.message, "data-component and data-each"
  end

  def test_collisions_on_different_elements_are_allowed
    # Same kinds, but on different refs — no collision.
    DC.check!(
      [
        dir(:text, ref_id: "g0"),
        dir(:unsafe_html, ref_id: "g1"),
      ],
      file: "x.gnt",
    )
  end

  # ---- element type checks ---------------------------------------

  def test_data_value_on_form_controls_ok
    DC.check!([dir(:value, tag: "input")], file: "x.gnt")
    DC.check!([dir(:value, tag: "textarea")], file: "x.gnt")
    DC.check!([dir(:value, tag: "select")], file: "x.gnt")
  end

  def test_data_value_on_div_raises_with_tag_in_message
    err = assert_raises(DC::Error) do
      DC.check!([dir(:value, tag: "div", line: 7)], file: "form.gnt")
    end
    assert_includes err.message, "form.gnt:7"
    assert_includes err.message, "<div>"
  end

  def test_data_checked_on_input_ok
    DC.check!([dir(:checked, tag: "input")], file: "x.gnt")
  end

  def test_data_checked_on_span_raises
    err = assert_raises(DC::Error) do
      DC.check!([dir(:checked, tag: "span", line: 5)], file: "x.gnt")
    end
    assert_includes err.message, "x.gnt:5"
    assert_includes err.message, "<span>"
  end

  # ---- gn-hidden conflict ----------------------------------------

  def test_data_class_gn_hidden_with_data_show_raises
    err = assert_raises(DC::Error) do
      DC.check!(
        [
          dir(:show, value: "@vis"),
          dir(:class_, value: "{ 'gn-hidden': @x }", line: 5),
        ],
        file: "x.gnt",
      )
    end
    assert_includes err.message, "x.gnt:5"
    assert_includes err.message, "gn-hidden"
  end

  def test_data_class_gn_hidden_with_data_hide_raises
    assert_raises(DC::Error) do
      DC.check!(
        [
          dir(:hide, value: "@vis"),
          dir(:class_, value: "{ 'gn-hidden': @x }"),
        ],
        file: "x.gnt",
      )
    end
  end

  def test_data_class_without_gn_hidden_key_ok
    DC.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ active: @a }"),
      ],
      file: "x.gnt",
    )
  end

  def test_data_class_gn_hidden_without_show_or_hide_ok
    # No data-show / data-hide on element → no conflict, even with the
    # reserved key in data-class. The standalone reservation warning is
    # a lint concern handled by the cross-reference linter, not a build error.
    DC.check!([dir(:class_, value: "{ 'gn-hidden': @x }")], file: "x.gnt")
  end

  def test_data_class_substring_gn_hidden_in_value_does_not_false_positive
    # Re-parse guards against substring matches inside values (which are
    # ivar / it_path only and can't carry that string anyway, but
    # defense in depth).
    DC.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ active: @a, 'not-gn-hidden-key': @b }"),
      ],
      file: "x.gnt",
    )
  end

  def test_malformed_data_class_does_not_raise_here
    # Parse errors are reported by emit_class with a cleaner message;
    # compatibility check just returns rather than double-erroring.
    DC.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ 'gn-hidden': }"),
      ],
      file: "x.gnt",
    )
  end
end
