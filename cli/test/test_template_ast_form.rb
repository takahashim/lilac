# frozen_string_literal: true

require "test_helper"

# Phase C: TemplateAST handling of form-related directives —
# <form> synthesis (bare form gets a :form directive), form scope
# stack tracking (data-field / data-button carry their enclosing form's
# name), form-control discovery + ref allocation for data-field containers.
class TestTemplateASTForm < Minitest::Test
  def parse(html)
    Lilac::CLI::TemplateAST.new(html).parse
  end

  def find(directives, kind, ref_id: nil)
    directives.find { |d| d.kind == kind && (ref_id.nil? || d.ref_id == ref_id) }
  end

  # ---- <form> synthesis -------------------------------------------

  def test_bare_form_gets_synthetic_form_directive
    result = parse(%(<form><input data-field="email" type="email"></form>))
    f = find(result.directives, :form)
    refute_nil f, "expected a :form directive on the bare <form>"
    assert_equal "form", f.element_tag
    assert_equal "", f.value  # synthetic marker for bare form
    assert_equal :default, f.form_scope
  end

  def test_named_form_carries_data_form_value
    result = parse(%(<form data-form="signup"><input data-field="email" type="email"></form>))
    f = find(result.directives, :form)
    assert_equal "signup", f.value
    assert_equal :signup, f.form_scope
  end

  # ---- form_scope on data-field / data-button ---------------------

  def test_data_field_inherits_default_scope_from_bare_form
    result = parse(%(<form><div data-field="email"><input></div></form>))
    field = find(result.directives, :field)
    assert_equal :default, field.form_scope
  end

  def test_data_field_inherits_named_scope_from_form
    result = parse(%(<form data-form="signup"><div data-field="email"><input></div></form>))
    field = find(result.directives, :field)
    assert_equal :signup, field.form_scope
  end

  def test_data_button_inherits_form_scope
    result = parse(%(<form data-form="login"><button data-button="submit">Login</button></form>))
    button = find(result.directives, :button)
    assert_equal :login, button.form_scope
  end

  def test_data_field_without_form_ancestor_defaults_to_default_scope
    # No enclosing <form> — scope still resolves to :default (component's
    # implicit default form).
    result = parse(%(<div data-field="query"><input></div>))
    field = find(result.directives, :field)
    assert_equal :default, field.form_scope
  end

  # ---- field_input_ref allocation ----------------------------------

  def test_field_on_container_div_allocates_separate_input_ref
    result = parse(%(<form><div data-field="email"><input></div></form>))
    field = find(result.directives, :field)
    refute_nil field.field_input_ref
    refute_equal field.ref_id, field.field_input_ref, "input should have its own ref"
    # The HTML should now have a synthetic data-ref on the input.
    assert_match(/<input[^>]*data-ref="#{field.field_input_ref}"/, result.html)
  end

  def test_field_on_input_directly_uses_own_ref
    result = parse(%(<form><input data-field="email" type="email"></form>))
    field = find(result.directives, :field)
    assert_equal field.ref_id, field.field_input_ref,
                 "data-field on <input> should reuse the input's own ref"
  end

  def test_field_supports_textarea_and_select_form_controls
    result = parse(%(<form><div data-field="bio"><textarea></textarea></div></form>))
    field = find(result.directives, :field)
    refute_nil field.field_input_ref

    result = parse(%(<form><div data-field="region"><select><option>A</option></select></div></form>))
    field = find(result.directives, :field)
    refute_nil field.field_input_ref
  end

  # ---- sibling form scopes (form stack pops correctly) -----------

  def test_sibling_forms_assign_distinct_scopes
    # HTML5 disallows nested <form>, so the realistic multi-scope case
    # is sibling forms within the same component. Each field carries
    # its enclosing form's scope name.
    html = <<~HTML
      <div>
        <form data-form="login">
          <input data-field="username" type="text">
        </form>
        <form data-form="signup">
          <input data-field="email" type="email">
        </form>
      </div>
    HTML
    result = parse(html)
    fields = result.directives.select { |d| d.kind == :field }
    by_value = fields.each_with_object({}) { |f, h| h[f.value] = f.form_scope }
    assert_equal :login,  by_value["username"]
    assert_equal :signup, by_value["email"]
  end
end
