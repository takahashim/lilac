# frozen_string_literal: true

require "test_helper"

# Per-directive emit behaviour for Codegen. Covers Phase B1 smoke set
# (data-component / data-text / data-on-X).
class TestDirectiveCodegen < Minitest::Test
  Directive = Grainet::CLI::Directive

  def gen(directives, source_path: nil)
    Grainet::CLI::Codegen.generate(
      component_name: "counter",
      directives: directives,
      source_path: source_path,
    )
  end

  def text(value:, ref_id: "g0", line: 1)
    Directive.new(kind: :text, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "span")
  end

  def on(name:, value:, ref_id: "g0", line: 1)
    Directive.new(kind: :on, name: name, value: value, ref_id: ref_id,
                  line: line, element_tag: "button")
  end

  def component(ref_id: "g0", line: 1)
    Directive.new(kind: :component, name: nil, value: "Counter", ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  # ---- data-text ---------------------------------------------------

  def test_data_text_emits_bind_text_call
    out = gen([text(value: "@count")])
    assert_includes out, "bind refs.g0, text: @count"
  end

  def test_data_text_with_it_path
    out = gen([text(value: "it.title")])
    assert_includes out, "bind refs.g0, text: it.title"
  end

  def test_data_text_strips_surrounding_whitespace
    out = gen([text(value: "  @count  ")])
    assert_includes out, "bind refs.g0, text: @count\n"
    refute_includes out, "text:   @count", "extra inline whitespace should have been stripped"
  end

  def test_data_text_invalid_value_raises
    err = assert_raises(Grainet::CLI::Codegen::Error) do
      gen([text(value: "@user.name", line: 7)], source_path: "counter.gnt")
    end
    assert_includes err.message, "counter.gnt:7"
    assert_includes err.message, "data-text"
  end

  def test_data_text_rejects_method_chain
    assert_raises(Grainet::CLI::Codegen::Error) { gen([text(value: "it.title.upcase")]) }
  end

  def test_data_text_rejects_bang
    assert_raises(Grainet::CLI::Codegen::Error) { gen([text(value: "@save!")]) }
  end

  # ---- data-on-X ---------------------------------------------------

  def test_data_on_click_emits_event_listener
    out = gen([on(name: "click", value: "increment")])
    assert_includes out, "refs.g0.on(:click) { |ev| increment(ev) }"
  end

  def test_data_on_keeps_kebab_in_quoted_symbol
    out = gen([on(name: "card-deleted", value: "handle")])
    assert_includes out, %(refs.g0.on(:"card-deleted") { |ev| handle(ev) })
  end

  def test_data_on_rejects_predicate_suffix
    err = assert_raises(Grainet::CLI::Codegen::Error) do
      gen([on(name: "click", value: "valid?", line: 4)], source_path: "ui.gnt")
    end
    assert_includes err.message, "ui.gnt:4"
    assert_includes err.message, "predicate"
  end

  def test_data_on_rejects_bang_method
    assert_raises(Grainet::CLI::Codegen::Error) { gen([on(name: "click", value: "save!")]) }
  end

  def test_data_on_strips_whitespace
    out = gen([on(name: "click", value: " increment ")])
    assert_includes out, "increment(ev)"
  end

  # ---- data-component ---------------------------------------------

  def test_data_component_emits_nothing
    # Only a component marker should leave the build output untouched.
    out = gen([component])
    assert_equal "", out
  end

  def test_data_component_mixed_with_text_emits_only_text
    out = gen([component, text(value: "@count", ref_id: "g1", line: 2)])
    assert_includes out, "bind refs.g1, text: @count"
    # data-component itself contributes nothing, so the body has exactly
    # one `bind` call (from data-text) — not two.
    assert_equal 1, out.scan(/^\s*bind /).length
  end

  # ---- source line comments ---------------------------------------

  def test_each_directive_gets_a_source_line_comment
    out = gen(
      [
        text(value: "@count", line: 3),
        on(name: "click", value: "incr", line: 4),
      ],
      source_path: "counter.gnt",
    )
    assert_match(/# counter\.gnt:3 — data-text="@count"/, out)
    assert_match(/# counter\.gnt:4 — data-on-click="incr"/, out)
  end

  def test_source_path_falls_back_when_omitted
    out = gen([text(value: "@count", line: 5)])
    assert_match(/\(template\):5/, out)
  end

  # ---- data-unsafe-html -------------------------------------------

  def unsafe_html(value:, ref_id: "g0", line: 1)
    Directive.new(kind: :unsafe_html, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def test_data_unsafe_html_emits_bind_html_call
    out = gen([unsafe_html(value: "@content")])
    assert_includes out, "bind refs.g0, html: @content"
  end

  def test_data_unsafe_html_rejects_method_chain
    assert_raises(Grainet::CLI::Codegen::Error) { gen([unsafe_html(value: "it.body.html_safe")]) }
  end

  # ---- data-value -------------------------------------------------

  def value_dir(value:, ref_id: "g0", line: 1)
    Directive.new(kind: :value, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "input")
  end

  def test_data_value_emits_bind_input
    out = gen([value_dir(value: "@title")])
    assert_includes out, "bind_input refs.g0, @title"
    refute_includes out, "property: :checked"
  end

  def test_data_value_rejects_it_path
    # data-value is two-way and writes back to the signal, so
    # iteration item field (`it.x` — immutable Data attribute) is
    # not a valid target. Per Section 6.2.
    err = assert_raises(Grainet::CLI::Codegen::Error) do
      gen([value_dir(value: "it.title", line: 3)], source_path: "form.gnt")
    end
    assert_includes err.message, "form.gnt:3"
    assert_includes err.message, "writable signal only"
  end

  # ---- data-checked -----------------------------------------------

  def checked_dir(value:, ref_id: "g0", line: 1)
    Directive.new(kind: :checked, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "input")
  end

  def test_data_checked_emits_bind_input_with_property
    out = gen([checked_dir(value: "@is_done")])
    assert_includes out, "bind_input refs.g0, @is_done, property: :checked"
  end

  def test_data_checked_rejects_it_path
    assert_raises(Grainet::CLI::Codegen::Error) { gen([checked_dir(value: "it.done")]) }
  end

  # ---- data-show / data-hide --------------------------------------

  def show(value:, ref_id: "g0", line: 1)
    Directive.new(kind: :show, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def hide(value:, ref_id: "g0", line: 1)
    Directive.new(kind: :hide, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def test_data_show_with_ivar_wraps_in_computed_with_negation
    out = gen([show(value: "@visible")])
    assert_includes out, %(bind refs.g0, class: { "gn-hidden" => computed { !@visible.value } })
  end

  def test_data_hide_with_ivar_wraps_in_computed_no_negation
    out = gen([hide(value: "@is_loading")])
    assert_includes out, %(bind refs.g0, class: { "gn-hidden" => computed { @is_loading.value } })
  end

  def test_data_show_with_it_path_omits_dot_value
    # `it.x` is plain Data attribute access — no `.value` to subscribe.
    out = gen([show(value: "it.visible")])
    assert_includes out, %(bind refs.g0, class: { "gn-hidden" => computed { !it.visible } })
  end

  def test_data_hide_with_bare_it
    out = gen([hide(value: "it")])
    assert_includes out, %(bind refs.g0, class: { "gn-hidden" => computed { it } })
  end

  def test_data_show_rejects_method_chain
    assert_raises(Grainet::CLI::Codegen::Error) { gen([show(value: "@user.active?")]) }
  end

  # ---- unimplemented directive fallback ---------------------------

  def test_unimplemented_directive_falls_back_to_placeholder_comment
    # `data-class` is implemented in a later phase; for now Codegen
    # emits a comment placeholder so the build doesn't choke.
    d = Directive.new(kind: :class_, name: nil, value: "{ active: @s }",
                      ref_id: "g0", line: 1, element_tag: "div")
    out = gen([d])
    assert_includes out, "data-class"
    refute_match(/^\s+bind /, out, "no real binding should be emitted yet")
  end
end
