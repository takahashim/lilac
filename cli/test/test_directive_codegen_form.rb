# frozen_string_literal: true

require "test_helper"

# Phase C: CLI codegen for data-form / data-field / data-button directives.
# Mirrors the runtime scanner's wire_form_submit / dispatch_field /
# dispatch_button behaviour as generated Ruby code in the Bindings module.
class TestDirectiveCodegenForm < Minitest::Test
  def gen(directives, source_path: nil)
    Lilac::CLI::Codegen.generate(
      component_name: "signup",
      directives: directives,
      source_path: source_path,
    )
  end

  def form_dir(value: "", ref_id: "lil0", line: 1, scope: :default)
    Lilac::CLI::Directive.new(kind: :form, name: nil, value: value, ref_id: ref_id,
                              line: line, element_tag: "form", form_scope: scope)
  end

  def field_dir(value:, ref_id: "lil0", input_ref: "lil1", line: 1, scope: :default, tag: "div")
    Lilac::CLI::Directive.new(kind: :field, name: nil, value: value, ref_id: ref_id,
                              line: line, element_tag: tag, form_scope: scope,
                              field_input_ref: input_ref)
  end

  def button_dir(value:, ref_id: "lil0", line: 1, scope: :default)
    Lilac::CLI::Directive.new(kind: :button, name: nil, value: value, ref_id: ref_id,
                              line: line, element_tag: "button", form_scope: scope)
  end

  # ---- emit_form (submit wire) -------------------------------------

  def test_form_emits_submit_listener_for_default_scope
    out = gen([form_dir(value: "", ref_id: "lil0", scope: :default)])
    assert_includes out, "refs.lil0.on(:submit)"
    assert_includes out, "form(:default)"
    assert_includes out, "invoke_button(:submit, __ev) if __f.has_button?(:submit)"
  end

  def test_form_emits_submit_listener_for_named_scope
    out = gen([form_dir(value: "signup", ref_id: "lil0", scope: :signup)])
    assert_includes out, "form(:signup)"
    assert_includes out, "refs.lil0.on(:submit)"
  end

  def test_form_preventDefault_is_called
    out = gen([form_dir(value: "", ref_id: "lil0", scope: :default)])
    assert_includes out, "__ev.call(:preventDefault)"
  end

  # ---- emit_field --------------------------------------------------

  def test_field_emits_register_and_bind_to
    out = gen([field_dir(value: "email", ref_id: "lil0", input_ref: "lil1", scope: :default)])
    assert_includes out, "form(:default).field(:email) unless form(:default).has_field?(:email)"
    assert_includes out, "form(:default)[:email].bind_to(refs.lil1)"
  end

  def test_field_uses_input_ref_distinct_from_container_ref
    # container has its own ref, input has a separate ref allocated by TemplateAST.
    out = gen([field_dir(value: "name", ref_id: "lil0", input_ref: "lil2")])
    assert_includes out, "bind_to(refs.lil2)"
    refute_includes out, "bind_to(refs.lil0)"   # container ref, not used by bind_to
  end

  def test_field_uses_named_form_scope
    out = gen([field_dir(value: "country", scope: :signup)])
    assert_includes out, "form(:signup).field(:country)"
    assert_includes out, "form(:signup)[:country].bind_to"
  end

  def test_field_raises_on_invalid_identifier
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([field_dir(value: "not valid")])
    end
    assert_includes err.message, "data-field"
    assert_includes err.message, "bare identifier"
  end

  def test_field_raises_when_no_input_found
    bad = field_dir(value: "email", input_ref: nil)
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([bad])
    end
    assert_includes err.message, "no <input>"
  end

  # ---- emit_button -------------------------------------------------

  def test_button_emits_click_invoke
    out = gen([button_dir(value: "save_draft", ref_id: "lil0", scope: :default)])
    assert_includes out, "refs.lil0.on(:click)"
    assert_includes out, "form(:default).invoke_button(:save_draft, __ev)"
  end

  def test_button_uses_named_form_scope
    out = gen([button_dir(value: "submit", ref_id: "lil2", scope: :signup)])
    assert_includes out, "form(:signup).invoke_button(:submit"
  end

  def test_button_raises_on_invalid_identifier
    err = assert_raises(Lilac::CLI::Codegen::Error) do
      gen([button_dir(value: "bad-name")])
    end
    assert_includes err.message, "data-button"
    assert_includes err.message, "bare identifier"
  end
end
