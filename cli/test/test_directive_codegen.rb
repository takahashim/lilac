# frozen_string_literal: true

require "test_helper"

# Per-directive emit behaviour for Codegen.
class TestDirectiveCodegen < Minitest::Test
  def gen(directives, source_path: nil)
    Lilac::CLI::Codegen.generate(
      component_name: "counter",
      directives: directives,
      source_path: source_path,
    )
  end

  def text(value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :text, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "span")
  end

  def on(name:, value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :on, name: name, value: value, ref_id: ref_id,
                  line: line, element_tag: "button")
  end

  def component(ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :component, name: nil, value: "Counter", ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  # ---- data-text ---------------------------------------------------

  def test_data_text_emits_bind_text_call
    out = gen([text(value: "@count")])
    assert_includes out, "bind refs.lil0, text: @count"
  end

  def test_data_text_with_it_path_wraps_in_computed
    # `bind ref, text: source` calls `source.value` internally — fine for
    # an ivar (Signal), broken for `it.title` (plain String). Wrapping
    # in `computed { ... }` makes the value flow through a Computed
    # whose `.value` returns the field.
    out = gen([text(value: "it.title")])
    assert_includes out, "bind refs.lil0, text: computed { it.title }"
  end

  def test_data_text_strips_surrounding_whitespace
    out = gen([text(value: "  @count  ")])
    assert_includes out, "bind refs.lil0, text: @count\n"
    refute_includes out, "text:   @count", "extra inline whitespace should have been stripped"
  end

  def test_data_text_invalid_value_raises
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([text(value: "@user.name", line: 7)], source_path: "counter.lil")
    end
    assert_includes err.message, "counter.lil:7"
    assert_includes err.message, "data-text"
  end

  def test_data_text_rejects_method_chain
    assert_raises(Lilac::CLI::Codegen::Error) { gen([text(value: "it.title.upcase")]) }
  end

  def test_data_text_rejects_bang
    assert_raises(Lilac::CLI::Codegen::Error) { gen([text(value: "@save!")]) }
  end

  # ---- data-on-X ---------------------------------------------------

  def test_data_on_click_emits_event_listener
    out = gen([on(name: "click", value: "increment")])
    assert_includes out, "refs.lil0.on(:click) { |ev| increment(ev) }"
  end

  def test_data_on_keeps_kebab_in_quoted_symbol
    out = gen([on(name: "card-deleted", value: "handle")])
    assert_includes out, %(refs.lil0.on(:"card-deleted") { |ev| handle(ev) })
  end

  def test_data_on_rejects_predicate_suffix
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([on(name: "click", value: "valid?", line: 4)], source_path: "ui.lil")
    end
    assert_includes err.message, "ui.lil:4"
    assert_includes err.message, "predicate"
  end

  def test_data_on_rejects_bang_method
    assert_raises(Lilac::CLI::Codegen::Error) { gen([on(name: "click", value: "save!")]) }
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
    out = gen([component, text(value: "@count", ref_id: "lil1", line: 2)])
    assert_includes out, "bind refs.lil1, text: @count"
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
      source_path: "counter.lil",
    )
    assert_match(/# counter\.lil:3 — data-text="@count"/, out)
    assert_match(/# counter\.lil:4 — data-on-click="incr"/, out)
  end

  def test_source_path_falls_back_when_omitted
    out = gen([text(value: "@count", line: 5)])
    assert_match(/\(template\):5/, out)
  end

  # ---- data-unsafe-html -------------------------------------------

  def unsafe_html(value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :unsafe_html, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def test_data_unsafe_html_emits_bind_html_call
    out = gen([unsafe_html(value: "@content")])
    assert_includes out, "bind refs.lil0, html: @content"
  end

  def test_data_unsafe_html_rejects_method_chain
    assert_raises(Lilac::CLI::Codegen::Error) { gen([unsafe_html(value: "it.body.html_safe")]) }
  end

  # data-value / data-checked were removed in Phase D (form-spec §10.8).
  # Use `<input data-field="X">` + the form gem instead.

  # ---- data-show / data-hide --------------------------------------

  def show(value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :show, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def hide(value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :hide, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def test_data_show_with_ivar_wraps_in_computed_with_negation
    out = gen([show(value: "@visible")])
    assert_includes out, %(bind refs.lil0, class: { "lil-hidden" => computed { !@visible.value } })
  end

  def test_data_hide_with_ivar_wraps_in_computed_no_negation
    out = gen([hide(value: "@is_loading")])
    assert_includes out, %(bind refs.lil0, class: { "lil-hidden" => computed { @is_loading.value } })
  end

  def test_data_show_with_it_path_omits_dot_value
    # `it.x` is plain Data attribute access — no `.value` to subscribe.
    out = gen([show(value: "it.visible")])
    assert_includes out, %(bind refs.lil0, class: { "lil-hidden" => computed { !it.visible } })
  end

  def test_data_hide_with_bare_it
    out = gen([hide(value: "it")])
    assert_includes out, %(bind refs.lil0, class: { "lil-hidden" => computed { it } })
  end

  def test_data_show_rejects_method_chain
    assert_raises(Lilac::CLI::Codegen::Error) { gen([show(value: "@user.active?")]) }
  end

  # ---- data-attr-X ------------------------------------------------

  def attr_dir(name:, value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :attr, name: name, value: value, ref_id: ref_id,
                  line: line, element_tag: "a")
  end

  def test_data_attr_emits_bind_attr_mapping
    out = gen([attr_dir(name: "href", value: "@url")])
    assert_includes out, %(bind refs.lil0, attr: { "href" => @url })
  end

  def test_data_attr_supports_it_path_wraps_in_computed
    out = gen([attr_dir(name: "data-id", value: "it.id")])
    assert_includes out, %(bind refs.lil0, attr: { "data-id" => computed { it.id } })
  end

  def test_data_attr_rejects_inline_event_handler
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([attr_dir(name: "onclick", value: "@x", line: 5)], source_path: "ui.lil")
    end
    assert_includes err.message, "ui.lil:5"
    assert_includes err.message, "banned attribute"
  end

  def test_data_attr_rejects_srcdoc_and_style
    assert_raises(Lilac::CLI::Codegen::Error) { gen([attr_dir(name: "srcdoc", value: "@x")]) }
    assert_raises(Lilac::CLI::Codegen::Error) { gen([attr_dir(name: "style",  value: "@x")]) }
  end

  def test_data_attr_rejects_invalid_value_shape
    assert_raises(Lilac::CLI::Codegen::Error) do
      gen([attr_dir(name: "href", value: "@url.to_s")])
    end
  end

  # ---- data-css-X -------------------------------------------------

  def css(name:, value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :css, name: name, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def test_data_css_emits_effect_set_style_with_double_dash_prefix
    out = gen([css(name: "progress", value: "@percent")])
    assert_includes out, %(effect { refs.lil0.set_style("--progress", @percent.value) })
  end

  def test_data_css_with_hyphenated_name
    out = gen([css(name: "theme-color", value: "@bg")])
    assert_includes out, %(effect { refs.lil0.set_style("--theme-color", @bg.value) })
  end

  def test_data_css_with_it_path_omits_dot_value
    out = gen([css(name: "progress", value: "it.percent")])
    assert_includes out, %(effect { refs.lil0.set_style("--progress", it.percent) })
  end

  def test_data_css_rejects_uppercase_name
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([css(name: "Color", value: "@bg", line: 4)], source_path: "x.lil")
    end
    assert_includes err.message, "x.lil:4"
    assert_includes err.message, "kebab-lowercase"
  end

  def test_data_css_rejects_digit_start
    assert_raises(Lilac::CLI::Codegen::Error) { gen([css(name: "3d-effect", value: "@x")]) }
  end

  def test_data_css_rejects_leading_hyphen
    # `data-css--theme-color` would produce `----theme-color` after auto-prepend.
    assert_raises(Lilac::CLI::Codegen::Error) { gen([css(name: "-theme", value: "@x")]) }
  end

  def test_data_css_rejects_invalid_value_shape
    assert_raises(Lilac::CLI::Codegen::Error) do
      gen([css(name: "progress", value: "@percent.to_s")])
    end
  end

  # ---- data-class -------------------------------------------------

  def class_dir(value:, ref_id: "lil0", line: 1)
    Lilac::CLI::Directive.new(kind: :class_, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "div")
  end

  def test_data_class_single_bare_pair
    out = gen([class_dir(value: "{ active: @on }")])
    assert_includes out, %(bind refs.lil0, class: { "active" => @on })
  end

  def test_data_class_multiple_pairs
    out = gen([class_dir(value: "{ active: @a, error: @e }")])
    assert_includes out, %(bind refs.lil0, class: { "active" => @a, "error" => @e })
  end

  def test_data_class_quoted_kebab_key
    out = gen([class_dir(value: "{ 'btn-primary': @primary }")])
    assert_includes out, %(bind refs.lil0, class: { "btn-primary" => @primary })
  end

  def test_data_class_tailwind_variant_key
    out = gen([class_dir(value: "{ 'hover:bg-blue-500': @h, 'md:text-lg': @d }")])
    assert_includes out, %("hover:bg-blue-500" => @h, "md:text-lg" => @d)
  end

  def test_data_class_mixed_bare_and_quoted
    out = gen([class_dir(value: "{ active: @a, 'btn-primary': @p }")])
    assert_includes out, %("active" => @a, "btn-primary" => @p)
  end

  def test_data_class_it_path_value_wraps_in_computed
    out = gen([class_dir(value: "{ done: it.done }")])
    assert_includes out, %("done" => computed { it.done })
  end

  def test_data_class_invalid_value_raises_with_location
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([class_dir(value: "{ active: @user.name }", line: 6)], source_path: "x.lil")
    end
    assert_includes err.message, "x.lil:6"
    assert_includes err.message, "invalid value"
  end

  def test_data_class_parse_error_is_wrapped_with_location
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([class_dir(value: "{ btn-primary: @p }", line: 9)], source_path: "x.lil")
    end
    assert_includes err.message, "x.lil:9"
  end

  # ---- data-each / data-key --------------------------------------

  def each_dir(value:, ref_id: "lil0", line: 1, scope_id: nil)
    Lilac::CLI::Directive.new(kind: :each, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "ul", scope_id: scope_id)
  end

  def key_dir(value:, ref_id: "lil0", line: 1, scope_id: nil)
    Lilac::CLI::Directive.new(kind: :key, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "ul", scope_id: scope_id)
  end

  def scoped_text(value:, ref_id: "lil1", scope_id: "lil0", line: 2)
    Lilac::CLI::Directive.new(kind: :text, name: nil, value: value, ref_id: ref_id,
                  line: line, element_tag: "span", scope_id: scope_id)
  end

  def test_data_each_with_data_key_emits_bind_list_and_iteration_method
    out = gen(
      [
        each_dir(value: "@todos", ref_id: "lil0"),
        key_dir(value: "id", ref_id: "lil0"),
        scoped_text(value: "it.title", ref_id: "lil1", scope_id: "lil0"),
      ],
    )
    assert_includes out,
                    %(bind_list refs.lil0, @todos, key: ->(it) { it.id }, ) +
                    %(template: "lil-each-counter-lil0" do |it, t|)
    assert_includes out, "bind_template_hook__each_lil0(it, t)"
    assert_includes out, "def bind_template_hook__each_lil0(it, t)"
    assert_includes out, "bind t.refs.lil1, text: computed { it.title }"
  end

  def test_data_each_without_data_key_falls_back_to_object_id
    out = gen([each_dir(value: "@items"), scoped_text(value: "it.label")])
    assert_includes out, "key: ->(it) { it.object_id }"
  end

  def test_data_each_iteration_method_emits_even_without_top_level_directives
    # `data-each` is itself a top-level directive (in nil scope), so
    # `bind_template_hook` exists with just the bind_list call.
    out = gen(
      [
        each_dir(value: "@items"),
        scoped_text(value: "it.label"),
      ],
    )
    assert_includes out, "def bind_template_hook"
    assert_includes out, "def bind_template_hook__each_lil0(it, t)"
  end

  def test_nested_data_each_generates_two_iteration_methods
    out = gen(
      [
        each_dir(value: "@categories", ref_id: "lil0"),
        key_dir(value: "id", ref_id: "lil0"),
        # Inner each lives in outer's scope, addressed via t.refs
        each_dir(value: "it.items", ref_id: "lil3", scope_id: "lil0"),
        key_dir(value: "id", ref_id: "lil3", scope_id: "lil0"),
        # Inner each body
        scoped_text(value: "it.title", ref_id: "lil4", scope_id: "lil3"),
      ],
    )
    assert_includes out, "def bind_template_hook__each_lil0(it, t)"
    assert_includes out, "def bind_template_hook__each_lil3(it, t)"
    assert_includes out,
                    %(bind_list t.refs.lil3, it.items, key: ->(it) { it.id }, ) +
                    %(template: "lil-each-counter-lil3" do |it, t|)
    assert_includes out, "bind t.refs.lil4, text: computed { it.title }"
  end

  def test_data_on_inside_data_each_passes_it_to_handler
    out = gen(
      [
        each_dir(value: "@todos"),
        Lilac::CLI::Directive.new(kind: :on, name: "click", value: "remove",
                      ref_id: "lil1", line: 2, element_tag: "button", scope_id: "lil0"),
      ],
    )
    assert_includes out, "t.refs.lil1.on(:click) { |ev| remove(it, ev) }"
  end

  def test_data_key_value_rejects_it_prefix
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([each_dir(value: "@todos", line: 3), key_dir(value: "it.id", line: 3)],
          source_path: "x.lil")
    end
    assert_includes err.message, "x.lil:3"
    assert_includes err.message, "bare field name"
  end

  def test_data_key_value_rejects_at_prefix
    assert_raises(Lilac::CLI::Codegen::Error) do
      gen([each_dir(value: "@todos"), key_dir(value: "@id")])
    end
  end

  def test_data_key_value_rejects_dot_access
    assert_raises(Lilac::CLI::Codegen::Error) do
      gen([each_dir(value: "@todos"), key_dir(value: "user.id")])
    end
  end

  def test_data_key_value_rejects_predicate_suffix
    assert_raises(Lilac::CLI::Codegen::Error) do
      gen([each_dir(value: "@todos"), key_dir(value: "valid?")])
    end
  end

  def test_data_key_without_data_each_on_same_element_raises
    # data-key on lil0, but data-each on lil1 — wrong element.
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen(
        [
          each_dir(value: "@todos", ref_id: "lil1"),
          key_dir(value: "id", ref_id: "lil0", line: 4),
        ],
        source_path: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:4"
    assert_includes err.message, "same element"
  end

  def test_top_level_and_iteration_directives_coexist
    # Top-level data-text + data-each-bodied directive together.
    out = gen(
      [
        Lilac::CLI::Directive.new(kind: :text, name: nil, value: "@title",
                      ref_id: "lilT", line: 1, element_tag: "h1", scope_id: nil),
        each_dir(value: "@todos"),
        scoped_text(value: "it.title"),
      ],
    )
    assert_includes out, "bind refs.lilT, text: @title"
    assert_includes out, "bind_list refs.lil0, @todos"
    assert_includes out, "bind t.refs.lil1, text: computed { it.title }"
  end

  # ---- compatibility integration ---------------------------------

  def test_codegen_propagates_collision_check_failure
    # `text + unsafe_html` on the same ref_id triggers
    # DirectiveCompatibility, surfaced before emit runs.
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      gen(
        [
          text(value: "@x", ref_id: "lil0"),
          unsafe_html(value: "@y", ref_id: "lil0", line: 2),
        ],
        source_path: "x.lil",
      )
    end
    assert_includes err.message, "x.lil:2"
    assert_includes err.message, "data-text and data-unsafe-html"
  end

  def test_codegen_propagates_form_scope_check_failure
    # data-form on a non-<form> element is a scope violation; codegen
    # surfaces the underlying DirectiveCompatibility::Error.
    err = assert_raises(Lilac::CLI::DirectiveCompatibility::Error) do
      gen(
        [
          Lilac::CLI::Directive.new(kind: :form, name: nil, value: "signup",
                                    ref_id: "lil0", line: 5, element_tag: "div"),
        ],
        source_path: "form.lil",
      )
    end
    assert_includes err.message, "form.lil:5"
    assert_includes err.message, "<div>"
  end

  # ---- unimplemented directive fallback ---------------------------

  def test_unimplemented_directive_falls_back_to_placeholder_comment
    # `data-arg-X` is implemented in a follow-up; for now Codegen emits
    # a comment placeholder so the build doesn't choke.
    d = Lilac::CLI::Directive.new(kind: :arg, name: "id", value: "it.id",
                      ref_id: "lil0", line: 1, element_tag: "li")
    out = gen([d])
    assert_includes out, "data-arg-id"
    refute_match(/^\s+bind_list /, out, "no real binding should be emitted yet")
  end
end
