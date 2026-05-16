# frozen_string_literal: true

require "test_helper"

class TestDirectiveCompatibility < Minitest::Test
  def dir(kind, ref_id: "llc0", line: 1, tag: "div", value: "@x", name: nil, scope_id: nil, element_attrs: nil)
    Lilac::CLI::Directive.new(
      kind: kind, name: name, value: value, ref_id: ref_id,
      line: line, element_tag: tag, scope_id: scope_id,
      element_attrs: element_attrs,
    )
  end

  # ---- collision pairs --------------------------------------------

  def test_text_and_unsafe_html_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:text), dir(:unsafe_html, line: 2)], file: "x.llc")
    end
    assert_includes err.message, "x.llc:2"
    assert_includes err.message, "data-text and data-unsafe-html"
  end

  def test_text_and_each_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:text, tag: "ul"), dir(:each, tag: "ul", value: "@items")], file: "x.llc")
    end
    assert_includes err.message, "data-text and data-each"
  end

  def test_show_and_hide_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:show), dir(:hide, line: 3)], file: "x.llc")
    end
    assert_includes err.message, "x.llc:3"
    assert_includes err.message, "data-show and data-hide"
  end

  def test_value_and_checked_on_same_element_raise
    # Collision check fires before element-type check, so we use a
    # type that's valid for the offending directive (text → fine for
    # data-value) — the test isolates the collision rule.
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      attrs = { "type" => "text" }
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:value, tag: "input", element_attrs: attrs),
          dir(:checked, tag: "input", line: 4, element_attrs: attrs),
        ],
        file: "x.llc",
      )
    end
    assert_includes err.message, "data-value and data-checked"
  end

  def test_component_and_each_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:component, value: "X", tag: "ul"),
          dir(:each, value: "@items", tag: "ul", line: 6),
        ],
        file: "x.llc",
      )
    end
    assert_includes err.message, "x.llc:6"
    assert_includes err.message, "data-component and data-each"
  end

  def test_collisions_on_different_elements_are_allowed
    # Same kinds, but on different refs — no collision.
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:text, ref_id: "llc0"),
        dir(:unsafe_html, ref_id: "llc1"),
      ],
      file: "x.llc",
    )
  end

  # ---- element type checks ---------------------------------------

  def test_data_value_on_form_controls_ok
    # `<input>` without explicit type defaults to text (HTML default).
    Lilac::CLI::DirectiveCompatibility.check!([dir(:value, tag: "input")], file: "x.llc")
    Lilac::CLI::DirectiveCompatibility.check!([dir(:value, tag: "input", element_attrs: { "type" => "email" })], file: "x.llc")
    Lilac::CLI::DirectiveCompatibility.check!([dir(:value, tag: "input", element_attrs: { "type" => "number" })], file: "x.llc")
    Lilac::CLI::DirectiveCompatibility.check!([dir(:value, tag: "textarea")], file: "x.llc")
    Lilac::CLI::DirectiveCompatibility.check!([dir(:value, tag: "select")], file: "x.llc")
  end

  def test_data_value_on_input_type_checkbox_raises
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [dir(:value, tag: "input", line: 3, element_attrs: { "type" => "checkbox" })],
        file: "form.llc",
      )
    end
    assert_includes err.message, "form.llc:3"
    assert_includes err.message, "checkbox"
    assert_includes err.message, "data-checked"
  end

  def test_data_value_on_div_raises_with_tag_in_message
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:value, tag: "div", line: 7)], file: "form.llc")
    end
    assert_includes err.message, "form.llc:7"
    assert_includes err.message, "<div>"
  end

  def test_data_checked_on_input_checkbox_or_radio_ok
    Lilac::CLI::DirectiveCompatibility.check!([dir(:checked, tag: "input", element_attrs: { "type" => "checkbox" })], file: "x.llc")
    Lilac::CLI::DirectiveCompatibility.check!([dir(:checked, tag: "input", element_attrs: { "type" => "radio" })],    file: "x.llc")
  end

  def test_data_checked_on_input_default_type_raises
    # No explicit type → defaults to "text" → not checkbox/radio.
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:checked, tag: "input", line: 4)], file: "x.llc")
    end
    assert_includes err.message, "x.llc:4"
    assert_includes err.message, "text"
  end

  def test_data_checked_on_input_type_text_raises
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [dir(:checked, tag: "input", line: 2, element_attrs: { "type" => "text" })],
        file: "x.llc",
      )
    end
    assert_includes err.message, "data-value"
  end

  def test_data_checked_on_span_raises
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:checked, tag: "span", line: 5)], file: "x.llc")
    end
    assert_includes err.message, "x.llc:5"
    assert_includes err.message, "<span>"
  end

  # ---- llc-hidden conflict ----------------------------------------

  def test_data_class_gn_hidden_with_data_show_raises
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:show, value: "@vis"),
          dir(:class_, value: "{ 'llc-hidden': @x }", line: 5),
        ],
        file: "x.llc",
      )
    end
    assert_includes err.message, "x.llc:5"
    assert_includes err.message, "llc-hidden"
  end

  def test_data_class_gn_hidden_with_data_hide_raises
    assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:hide, value: "@vis"),
          dir(:class_, value: "{ 'llc-hidden': @x }"),
        ],
        file: "x.llc",
      )
    end
  end

  def test_data_class_without_gn_hidden_key_ok
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ active: @a }"),
      ],
      file: "x.llc",
    )
  end

  def test_data_class_gn_hidden_without_show_or_hide_ok
    # No data-show / data-hide on element → no conflict, even with the
    # reserved key in data-class. The standalone reservation warning is
    # a lint concern handled by the cross-reference linter, not a build error.
    Lilac::CLI::DirectiveCompatibility.check!([dir(:class_, value: "{ 'llc-hidden': @x }")], file: "x.llc")
  end

  def test_data_class_substring_gn_hidden_in_value_does_not_false_positive
    # Re-parse guards against substring matches inside values (which are
    # ivar / it_path only and can't carry that string anyway, but
    # defense in depth).
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ active: @a, 'not-llc-hidden-key': @b }"),
      ],
      file: "x.llc",
    )
  end

  def test_malformed_data_class_does_not_raise_here
    # Parse errors are reported by emit_class with a cleaner message;
    # compatibility check just returns rather than double-erroring.
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ 'llc-hidden': }"),
      ],
      file: "x.llc",
    )
  end
end
