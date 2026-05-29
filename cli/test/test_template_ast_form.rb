# frozen_string_literal: true

require "test_helper"

# TemplateAST collection of form-related directives. Scanner-canonical:
# the CLI only collects :form / :field / :button records (for the lint
# layer) — the runtime form gem resolves scope + binds controls at mount,
# so the CLI no longer tracks form scope or allocates input refs.
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
    assert_equal "", f.value # synthetic marker for bare form
  end

  def test_named_form_carries_data_form_value
    result = parse(%(<form data-form="signup"><input data-field="email" type="email"></form>))
    f = find(result.directives, :form)
    assert_equal "signup", f.value
  end

  # ---- data-field / data-button collection ------------------------

  def test_data_field_collected_with_its_value
    result = parse(%(<form><div data-field="email"><input></div></form>))
    field = find(result.directives, :field)
    refute_nil field
    assert_equal "email", field.value
  end

  def test_data_button_collected_with_its_value
    result = parse(%(<form data-form="login"><button data-button="submit">Login</button></form>))
    button = find(result.directives, :button)
    refute_nil button
    assert_equal "submit", button.value
  end

  def test_data_field_without_form_ancestor_still_collected
    result = parse(%(<div data-field="query"><input></div>))
    field = find(result.directives, :field)
    refute_nil field
    assert_equal "query", field.value
  end

  def test_sibling_forms_collect_independent_field_directives
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
    values = result.directives.select { |d| d.kind == :field }.map(&:value).sort
    assert_equal %w[email username], values
  end
end
