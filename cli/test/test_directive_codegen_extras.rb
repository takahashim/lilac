# frozen_string_literal: true

require "test_helper"

# Codegen tests for the mruby-lilac-extras plug-in directives
# (data-tooltip, data-focus, data-autofocus). Mirrors
# test_directive_codegen.rb's per-directive coverage style.
class TestDirectiveCodegenExtras < Minitest::Test
  def gen(directives)
    Lilac::CLI::Codegen.generate(
      component_name: "host",
      directives: directives,
      source_path: nil,
    )
  end

  def directive(kind:, value:, ref_id: "lil0", line: 1, tag: "span", name: nil)
    Lilac::CLI::Directive.new(
      kind: kind, name: name, value: value, ref_id: ref_id,
      line: line, element_tag: tag,
    )
  end

  # ---- data-tooltip ----------------------------------------------

  def test_tooltip_ivar_emits_attr_bind
    out = gen([directive(kind: :tooltip, value: "@msg")])
    assert_includes out, "data-tooltip"
    assert_includes out, "bind refs.lil0, attr: { \"title\" => @msg }"
  end

  def test_tooltip_bare_ident_uses_iteration_source
    # Bare-ident is wrapped in computed { it[...] } at runtime via
    # Value::BareIdent#bind_source — codegen emits the same expression.
    out = gen([directive(kind: :tooltip, value: "name", tag: "li")])
    assert_includes out, "bind refs.lil0, attr: { \"title\" =>"
  end

  def test_tooltip_invalid_value_raises_build_error
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([directive(kind: :tooltip, value: "@bad.value")])
    end
    assert_includes err.message, "data-tooltip"
  end

  # ---- data-autofocus --------------------------------------------

  def test_autofocus_emits_focus_call
    out = gen([directive(kind: :autofocus, value: "", tag: "input")])
    assert_includes out, "data-autofocus"
    assert_includes out, "refs.lil0.to_js.call(:focus)"
  end
end
