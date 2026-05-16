# frozen_string_literal: true

require "test_helper"

class TestCodegen < Minitest::Test
  Directive = Grainet::CLI::Directive

  def gen(name, directives, source_path: nil)
    Grainet::CLI::Codegen.generate(
      component_name: name,
      directives: directives,
      source_path: source_path,
    )
  end

  def directive(kind:, value:, ref_id: "g0", name: nil, line: 1, tag: "div")
    Directive.new(
      kind: kind,
      name: name,
      value: value,
      ref_id: ref_id,
      line: line,
      element_tag: tag,
    )
  end

  def test_empty_directives_returns_empty_string
    assert_equal "", gen("counter", [])
  end

  def test_emits_namespaced_module_and_include
    out = gen("counter", [directive(kind: :text, value: "@count")])
    assert_includes out, "module Grainet; module Bindings; module Counter"
    assert_includes out, "Counter.include(Grainet::Bindings::Counter)"
  end

  def test_emits_bind_template_hook_method
    out = gen("counter", [directive(kind: :text, value: "@count")])
    assert_includes out, "def bind_template_hook"
    # Body has one comment per directive (Phase A1 placeholder).
    assert_match(/data-text="@count".*g0/, out)
  end

  def test_kebab_component_name_becomes_pascalcase
    out = gen("user-profile", [directive(kind: :text, value: "@name")])
    assert_includes out, "Grainet::Bindings::UserProfile"
    assert_includes out, "UserProfile.include(Grainet::Bindings::UserProfile)"
  end

  def test_double_dash_creates_namespace
    out = gen("admin--user-card", [directive(kind: :text, value: "@name")])
    assert_includes out, "module Admin; module UserCard"
    assert_includes out, "Admin::UserCard.include(Grainet::Bindings::Admin::UserCard)"
  end

  def test_x_family_directive_in_comment
    out = gen("counter", [directive(kind: :on, name: "click", value: "increment")])
    assert_match(/data-on-click="increment"/, out)
  end

  def test_source_path_appears_in_comment
    out = gen(
      "counter",
      [directive(kind: :text, value: "@count", line: 5)],
      source_path: "/path/to/counter.gnt",
    )
    assert_match(/counter\.gnt:5/, out)
  end

  def test_source_path_falls_back_when_omitted
    out = gen("counter", [directive(kind: :text, value: "@count", line: 5)])
    assert_match(/\(template\):5/, out)
  end

  def test_multiple_directives_each_get_a_comment_line
    out = gen("counter", [
      directive(kind: :text, value: "@count", line: 1),
      directive(kind: :on, name: "click", value: "increment", line: 2),
    ])
    body = out[/def bind_template_hook(.*)end/m, 1]
    refute_nil body
    assert_equal 2, body.scan(/^\s*#/).length
  end

  def test_class_kind_renders_as_data_class
    out = gen("counter", [directive(kind: :class_, value: "{ a: @s }")])
    assert_match(/data-class/, out)
    refute_match(/data-class_/, out, "trailing _ must not leak")
  end

  def test_invalid_component_name_raises
    assert_raises(ArgumentError) { gen("--foo", [directive(kind: :text, value: "@x")]) }
    assert_raises(ArgumentError) { gen("foo--", [directive(kind: :text, value: "@x")]) }
  end
end
