# frozen_string_literal: true

require "test_helper"

class TestBuildError < Minitest::Test
  def loc(file, line)
    Lilac::CLI::SourceLocation.new(file: file, line: line)
  end

  def test_structured_form_renders_header_and_body
    err = Lilac::CLI::BuildError.new("data-value not allowed on <div>", at: loc("form.llc", 8))
    expected = <<~MSG.chomp
      lilac: build error in form.llc:8
        data-value not allowed on <div>
    MSG
    assert_equal expected, err.message
  end

  def test_suggestion_appended_after_body
    err = Lilac::CLI::BuildError.new(
      "data-key is not a bare field name.",
      at: loc("x.llc", 4),
      suggestion: "Use `data-key=\"id\"` (no `it.` prefix, no `@`, no `.`, no `?`).",
    )
    expected = <<~MSG.chomp
      lilac: build error in x.llc:4
        data-key is not a bare field name.
        Use `data-key="id"` (no `it.` prefix, no `@`, no `.`, no `?`).
    MSG
    assert_equal expected, err.message
  end

  def test_multiline_body_is_indented_per_line
    err = Lilac::CLI::BuildError.new("first line\nsecond line", at: loc("x.llc", 1))
    expected = <<~MSG.chomp
      lilac: build error in x.llc:1
        first line
        second line
    MSG
    assert_equal expected, err.message
  end

  def test_bare_string_form_passes_message_through
    err = Lilac::CLI::BuildError.new("just a message")
    assert_equal "just a message", err.message
  end

  def test_raise_with_just_string_keeps_backward_compat
    err = assert_raises(Lilac::CLI::BuildError) { raise Lilac::CLI::BuildError, "boom" }
    assert_equal "boom", err.message
  end

  def test_subclasses_inherit_formatter
    codegen_err = Lilac::CLI::Codegen::Error.new("oops", at: loc("a.llc", 1))
    assert_includes codegen_err.message, "lilac: build error in a.llc:1"
    assert_includes codegen_err.message, "  oops"

    compat_err = Lilac::CLI::DirectiveCompatibility::Error.new("clash", at: loc("b.llc", 2))
    assert_includes compat_err.message, "lilac: build error in b.llc:2"
    assert_includes compat_err.message, "  clash"
  end
end
