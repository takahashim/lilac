# frozen_string_literal: true

require "test_helper"

# Structural tests for Codegen.generate — empty/skeleton/naming concerns.
# Per-directive emit behaviour lives in test_directive_codegen.rb.
class TestCodegen < Minitest::Test
  Directive = Grainet::CLI::Directive

  def gen(name, directives, source_path: nil)
    Grainet::CLI::Codegen.generate(
      component_name: name,
      directives: directives,
      source_path: source_path,
    )
  end

  def text_directive(value: "@count", ref_id: "g0", line: 1)
    Directive.new(
      kind: :text,
      name: nil,
      value: value,
      ref_id: ref_id,
      line: line,
      element_tag: "span",
    )
  end

  def test_empty_directives_returns_empty_string
    assert_equal "", gen("counter", [])
  end

  def test_all_no_op_directives_yield_empty_output
    # `data-component` alone has no codegen target — only the runtime
    # autoregister consumes it. The emitter should suppress the module
    # entirely instead of emitting an empty `bind_template_hook`.
    component_directive = Directive.new(
      kind: :component,
      name: nil,
      value: "Counter",
      ref_id: "g0",
      line: 1,
      element_tag: "div",
    )
    assert_equal "", gen("counter", [component_directive])
  end

  def test_emits_namespaced_module_and_include
    out = gen("counter", [text_directive])
    assert_includes out, "module Grainet; module Bindings; module Counter"
    assert_includes out, "Counter.include(Grainet::Bindings::Counter)"
  end

  def test_emits_bind_template_hook_method
    out = gen("counter", [text_directive])
    assert_includes out, "def bind_template_hook"
    assert_includes out, "end"
  end

  def test_kebab_component_name_becomes_pascalcase
    out = gen("user-profile", [text_directive(value: "@name")])
    assert_includes out, "Grainet::Bindings::UserProfile"
    assert_includes out, "UserProfile.include(Grainet::Bindings::UserProfile)"
  end

  def test_double_dash_creates_namespace
    out = gen("admin--user-card", [text_directive(value: "@name")])
    assert_includes out, "module Admin; module UserCard"
    assert_includes out, "Admin::UserCard.include(Grainet::Bindings::Admin::UserCard)"
  end

  def test_invalid_component_name_raises
    assert_raises(ArgumentError) { gen("--foo", [text_directive]) }
    assert_raises(ArgumentError) { gen("foo--", [text_directive]) }
    assert_raises(ArgumentError) { gen("foo---bar", [text_directive]) }
  end
end
