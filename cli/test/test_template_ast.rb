# frozen_string_literal: true

require "test_helper"

class TestTemplateAST < Minitest::Test
  def parse(html, source_path: nil)
    Lilac::CLI::TemplateAST.new(html, source_path: source_path).parse
  end

  def test_assigns_synthetic_ref_to_element_with_directive
    result = parse(%(<div><span data-text="@count">0</span></div>))
    assert_equal 1, result.directives.length
    d = result.directives.first
    assert_equal :text, d.kind
    assert_equal "@count", d.value
    assert_equal "lil0", d.ref_id
    assert_equal "span", d.element_tag
    assert_includes result.html, %(data-ref="lil0")
  end

  def test_uses_explicit_data_ref_when_present
    result = parse(%(<span data-ref="status" data-text="@count">0</span>))
    d = result.directives.first
    assert_equal "status", d.ref_id
    # No synthetic lilN added when explicit ref exists.
    refute_match(/data-ref="lil0"/, result.html)
  end

  def test_multiple_directives_on_one_element_share_ref
    html = %(<button data-on-click="add" data-class="{ active: @s }">+</button>)
    result = parse(html)
    assert_equal 2, result.directives.length
    refs = result.directives.map(&:ref_id).uniq
    assert_equal 1, refs.length
    assert_equal "lil0", refs.first
  end

  def test_x_family_directive_carries_name
    html = %(<button data-on-mouse-enter="hover">x</button>)
    d = parse(html).directives.first
    assert_equal :on, d.kind
    assert_equal "mouse-enter", d.name
    assert_equal "hover", d.value
  end

  def test_attr_family_directive_carries_attribute_name
    d = parse(%(<a data-attr-href="@url">link</a>)).directives.first
    assert_equal :attr, d.kind
    assert_equal "href", d.name
    assert_equal "@url", d.value
  end

  def test_css_family_directive_carries_variable_name
    d = parse(%(<div data-css-theme-color="@color"></div>)).directives.first
    assert_equal :css, d.kind
    assert_equal "theme-color", d.name
  end

  def test_arg_family_directive_carries_arg_name
    directives = parse(%(<div data-component="X" data-arg-id="it.id"></div>)).directives
    arg = directives.find { |x| x.kind == :arg }
    assert_equal "id", arg.name
    assert_equal "it.id", arg.value
  end

  def test_each_and_key_collected_together
    html = %(<ul data-each="@todos" data-key="id"><li></li></ul>)
    kinds = parse(html).directives.map(&:kind).sort
    assert_equal %i[each key], kinds
  end

  def test_synthetic_ref_counter_increments_per_element
    html = <<~HTML
      <button data-on-click="a">A</button>
      <button data-on-click="b">B</button>
      <span data-text="@c"></span>
    HTML
    result = parse(html)
    ref_ids = result.directives.map(&:ref_id)
    assert_equal %w[lil0 lil1 lil2], ref_ids
  end

  def test_directives_collected_in_document_order
    html = <<~HTML
      <span data-text="@a">x</span>
      <span data-text="@b">y</span>
      <span data-text="@c">z</span>
    HTML
    values = parse(html).directives.map(&:value)
    assert_equal %w[@a @b @c], values
  end

  def test_class_directive_kind_uses_class_underscore
    d = parse(%(<div data-class="{ active: @s }">x</div>)).directives.first
    assert_equal :class_, d.kind
  end

  def test_source_line_tracking
    html = <<~HTML
      <div>
        <button data-on-click="m">A</button>
        <span data-text="@x">B</span>
      </div>
    HTML
    lines = parse(html).directives.map(&:line)
    # Nokogiri 1-based; button is on line 2, span on line 3 inside fragment.
    assert lines.all? { |l| l.is_a?(Integer) && l.positive? }
    assert_equal lines.sort, lines  # monotonic
  end

  def test_empty_template_returns_empty_directives
    result = parse(%(<div>no directives</div>))
    assert_empty result.directives
    assert_empty result.refs_map
  end

  def test_refs_map_contains_tag_and_line
    result = parse(%(<button data-on-click="m">x</button>))
    info = result.refs_map["lil0"]
    assert_equal "button", info[:tag]
    assert_kind_of Integer, info[:line]
  end

  def test_nested_template_directives_walked
    # `<template>` element inside the body (e.g. a future inner template
    # marker). Nokogiri descends into <template>'s content fragment.
    html = <<~HTML
      <div>
        <template data-template="row">
          <li data-text="it.title"></li>
        </template>
      </div>
    HTML
    result = parse(html)
    refute_empty result.directives, "expected directives inside <template> to be discovered"
  end

  def test_unrelated_data_attributes_are_not_directives
    # data-component / data-ref / data-template are markers handled by
    # other layers — they must not appear as `Directive` records here.
    html = %(<div data-component="C" data-ref="root" data-template="t"></div>)
    result = parse(html)
    assert_empty result.directives, "non-directive data-* attrs should be ignored"
  end

  def test_html_round_trip_preserves_content_text
    # Nokogiri normalizes attribute quoting and may collapse boolean
    # attributes, but the text content should round-trip intact.
    result = parse(%(<p>Hello <strong>world</strong>!</p>))
    assert_includes result.html, "Hello"
    assert_includes result.html, "<strong>world</strong>"
    assert_includes result.html, "!"
  end

  # ---- data-each scope tracking + body extraction ----------------

  def test_top_level_directives_have_nil_scope_id
    result = parse(%(<span data-text="@count">0</span>))
    assert_nil result.directives.first.scope_id
  end

  def test_directives_inside_data_each_carry_outer_ref_id_as_scope
    html = <<~HTML
      <ul data-each="@todos" data-key="id">
        <li><span data-text="it.title"></span></li>
      </ul>
    HTML
    result = parse(html)
    each_dir = result.directives.find { |d| d.kind == :each }
    text_dir = result.directives.find { |d| d.kind == :text }
    assert_nil each_dir.scope_id, "data-each itself lives at the outer scope"
    assert_equal each_dir.ref_id, text_dir.scope_id, "data-text under data-each scoped to its ref_id"
  end

  def test_data_each_body_is_extracted_into_synthetic_template
    html = %(<ul data-each="@items"><li><span data-text="it.label"></span></li></ul>)
    result = parse(html)

    assert_equal 1, result.synthetic_templates.length
    st = result.synthetic_templates.first
    each_dir = result.directives.find { |d| d.kind == :each }
    assert_equal each_dir.ref_id, st.ref_id
    assert_includes st.html, "<li>"
    assert_includes st.html, %(data-text="it.label")
    # Outer container survives, but the iteration body is stripped from
    # the main HTML — the runtime bind_list repopulates per item.
    assert_includes result.html, "<ul"
    refute_match(/<li/, result.html, "iteration body should be stripped from main HTML")
  end

  # ---- data-component detection (collision check only) ----------

  def test_pure_data_component_element_produces_no_directive_and_no_synthetic_ref
    # Common case: bare `<div data-component="X">` — the runtime
    # autoregister handles mount via the attribute, so we deliberately
    # don't add a synthetic ref or a Directive record. dist HTML must
    # stay byte-identical to what the user wrote.
    html = %(<div data-component="X"></div>)
    result = parse(html)
    assert_empty result.directives
    refute_match(/data-ref="g/, result.html)
  end

  def test_data_component_with_data_each_records_both_directives_on_same_ref
    # When data-component coexists with another directive (here
    # data-each), both records appear with a shared ref_id so the
    # collision check in DirectiveCompatibility can see them together.
    html = %(<ul data-component="X" data-each="@items"></ul>)
    result = parse(html)
    kinds = result.directives.map(&:kind)
    assert_includes kinds, :component
    assert_includes kinds, :each
    refs = result.directives.map(&:ref_id).uniq
    assert_equal 1, refs.length
  end

  def test_nested_data_each_produces_two_synthetic_templates_with_independent_scopes
    html = <<~HTML
      <ul data-each="@categories" data-key="id">
        <li>
          <h3 data-text="it.name"></h3>
          <ul data-each="it.items" data-key="id">
            <li data-text="it.title"></li>
          </ul>
        </li>
      </ul>
    HTML
    result = parse(html)

    each_dirs = result.directives.select { |d| d.kind == :each }
    outer, inner = each_dirs
    assert_nil outer.scope_id
    assert_equal outer.ref_id, inner.scope_id

    # Both data-each bodies extracted.
    assert_equal 2, result.synthetic_templates.length

    text_dirs = result.directives.select { |d| d.kind == :text }
    h3_dir = text_dirs.find { |d| d.value == "it.name" }
    li_dir = text_dirs.find { |d| d.value == "it.title" }
    assert_equal outer.ref_id, h3_dir.scope_id
    assert_equal inner.ref_id, li_dir.scope_id

    # Outer synthetic template body includes the inner <ul> (now empty)
    # but not the inner <li> (extracted into its own template).
    outer_st = result.synthetic_templates.find { |st| st.ref_id == outer.ref_id }
    assert_includes outer_st.html, "<ul"
    refute_includes outer_st.html, "data-text=\"it.title\""
  end

  # ---- data-ref duplicate detection ------------------------------

  def test_duplicate_explicit_data_ref_in_same_scope_raises
    html = <<~HTML
      <div>
        <span data-ref="email" data-text="@a"></span>
        <input data-ref="email" data-value="@b">
      </div>
    HTML
    err = assert_raises(Lilac::CLI::TemplateAST::Error) do
      Lilac::CLI::TemplateAST.new(html, source_path: "form.lil").parse
    end
    assert_includes err.message, "form.lil"
    assert_includes err.message, "Duplicate data-ref \"email\""
  end

  def test_explicit_ref_without_other_directives_still_participates
    # `data-ref` alone (no other directive) doesn't allocate a
    # Directive, but the ref name must still be registered so a later
    # duplicate trips the check.
    html = <<~HTML
      <div>
        <input data-ref="email">
        <input data-ref="email" data-value="@x">
      </div>
    HTML
    assert_raises(Lilac::CLI::TemplateAST::Error) do
      Lilac::CLI::TemplateAST.new(html, source_path: "x.lil").parse
    end
  end

  def test_synthetic_ref_skips_user_chosen_collision
    # The user wrote data-ref="lil0" — our auto-allocator must skip lil0
    # and pick lil1 (or later) for the synthetic ref instead of stomping.
    html = %(<div><span data-ref="lil0">x</span><b data-text="@v"></b></div>)
    result = Lilac::CLI::TemplateAST.new(html).parse
    text_dir = result.directives.find { |d| d.kind == :text }
    refute_equal "lil0", text_dir.ref_id
  end

  def test_same_ref_name_across_data_each_scopes_does_not_collide
    # Inner `<li data-ref="row">` opens a fresh ref scope, so the same
    # name used at top level does not conflict.
    html = <<~HTML
      <div data-ref="row" data-text="@title">
        <ul data-each="@items">
          <li data-ref="row" data-text="it.label"></li>
        </ul>
      </div>
    HTML
    # No raise; both refs coexist.
    Lilac::CLI::TemplateAST.new(html, source_path: "ok.lil").parse
  end

  def test_same_ref_name_across_data_component_scopes_does_not_collide
    # Per spec Section 9, `data-component` opens its own ref namespace
    # at runtime — the parent's `data-ref="x"` and a nested child's
    # `data-ref="x"` address different elements.
    html = <<~HTML
      <div data-ref="root" data-text="@title">
        <div data-component="Child">
          <span data-ref="root" data-text="@inner"></span>
        </div>
      </div>
    HTML
    Lilac::CLI::TemplateAST.new(html, source_path: "ok.lil").parse
  end
end
