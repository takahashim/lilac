# frozen_string_literal: true

require "test_helper"

class TestDirectiveCompatibility < Minitest::Test
  def dir(kind, ref_id: "lil0", line: 1, tag: "div", value: "@x", name: nil, scope_id: nil, element_attrs: nil)
    Lilac::CLI::Directive.new(
      kind: kind, name: name, value: value, ref_id: ref_id,
      line: line, element_tag: tag, scope_id: scope_id,
      element_attrs: element_attrs,
    )
  end

  # ---- collision pairs --------------------------------------------

  def test_text_and_unsafe_html_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:text), dir(:unsafe_html, line: 2)], file: "x.lil")
    end
    assert_includes err.message, "x.lil:2"
    assert_includes err.message, "data-text and data-unsafe-html"
  end

  def test_text_and_each_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:text, tag: "ul"), dir(:each, tag: "ul", value: "@items")], file: "x.lil")
    end
    assert_includes err.message, "data-text and data-each"
  end

  def test_show_and_hide_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!([dir(:show), dir(:hide, line: 3)], file: "x.lil")
    end
    assert_includes err.message, "x.lil:3"
    assert_includes err.message, "data-show and data-hide"
  end

  # data-value / data-checked collision pair was removed in Phase D
  # (form-spec §10.8). The Phase-E successor `data-bind` has its own
  # collision with `data-field` (form-scope binding) tested below.

  def test_bind_and_field_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:bind, value: "@qty", tag: "input"),
          dir(:field, value: "qty", tag: "input", line: 4),
        ],
        file: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:4"
    assert_includes err.message, "data-bind and data-field"
  end

  def test_component_and_each_on_same_element_raise
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:component, value: "X", tag: "ul"),
          dir(:each, value: "@items", tag: "ul", line: 6),
        ],
        file: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:6"
    assert_includes err.message, "data-component and data-each"
  end

  def test_collisions_on_different_elements_are_allowed
    # Same kinds, but on different refs — no collision.
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:text, ref_id: "lil0"),
        dir(:unsafe_html, ref_id: "lil1"),
      ],
      file: "x.lil",
    )
  end

  # ---- element type checks ---------------------------------------
  # data-value / data-checked element-type rules removed in Phase D
  # (form-spec §10.8); the runtime form gem owns form-control selection
  # via data-field auto-detect.

  # ---- lil-hidden conflict ----------------------------------------

  def test_data_class_gn_hidden_with_data_show_raises
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:show, value: "@vis"),
          dir(:class_, value: "{ 'lil-hidden': @x }", line: 5),
        ],
        file: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:5"
    assert_includes err.message, "lil-hidden"
  end

  def test_data_class_gn_hidden_with_data_hide_raises
    assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:hide, value: "@vis"),
          dir(:class_, value: "{ 'lil-hidden': @x }"),
        ],
        file: "x.lil",
      )
    end
  end

  def test_data_class_without_gn_hidden_key_ok
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ active: @a }"),
      ],
      file: "x.lil",
    )
  end

  def test_data_class_gn_hidden_without_show_or_hide_ok
    # No data-show / data-hide on element → no conflict, even with the
    # reserved key in data-class. The standalone reservation warning is
    # a lint concern handled by the cross-reference linter, not a build error.
    Lilac::CLI::DirectiveCompatibility.check!([dir(:class_, value: "{ 'lil-hidden': @x }")], file: "x.lil")
  end

  def test_data_class_substring_gn_hidden_in_value_does_not_false_positive
    # Re-parse guards against substring matches inside values (which are
    # ivar / bare ident only and can't carry that string anyway, but
    # defense in depth).
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ active: @a, 'not-lil-hidden-key': @b }"),
      ],
      file: "x.lil",
    )
  end

  def test_malformed_data_class_does_not_raise_here
    # Parse errors are reported by emit_class with a cleaner message;
    # compatibility check just returns rather than double-erroring.
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:show, value: "@vis"),
        dir(:class_, value: "{ 'lil-hidden': }"),
      ],
      file: "x.lil",
    )
  end

  # ---- form scope rules (Phase C) ---------------------------------

  def test_data_form_on_non_form_element_raises
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [dir(:form, value: "signup", tag: "div", line: 3)],
        file: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:3"
    assert_includes err.message, "<div>"
    assert_includes err.message, "only allowed on <form>"
  end

  def test_data_form_on_form_element_ok
    Lilac::CLI::DirectiveCompatibility.check!(
      [dir(:form, value: "signup", tag: "form")],
      file: "x.lil",
    )
  end

  def test_multiple_bare_form_raises_default_collision
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      Lilac::CLI::DirectiveCompatibility.check!(
        [
          dir(:form, value: "", tag: "form", ref_id: "lil0", line: 2),
          dir(:form, value: "", tag: "form", ref_id: "lil1", line: 5),
        ],
        file: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:5"
    assert_includes err.message, ":default scope"
  end

  def test_bare_form_and_named_form_coexist_ok
    # `data-form="signup"` has a name; the other bare form takes :default.
    # No collision.
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:form, value: "", tag: "form", ref_id: "lil0"),
        dir(:form, value: "signup", tag: "form", ref_id: "lil1"),
      ],
      file: "x.lil",
    )
  end

  def test_multiple_named_forms_ok
    Lilac::CLI::DirectiveCompatibility.check!(
      [
        dir(:form, value: "login",  tag: "form", ref_id: "lil0"),
        dir(:form, value: "signup", tag: "form", ref_id: "lil1"),
      ],
      file: "x.lil",
    )
  end
end
