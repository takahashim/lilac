# frozen_string_literal: true

require "test_helper"

class TestBuildError < Minitest::Test
  def loc(file, line)
    Grainet::CLI::SourceLocation.new(file: file, line: line)
  end

  def test_structured_form_renders_header_and_body
    err = Grainet::CLI::BuildError.new("data-value not allowed on <div>", at: loc("form.gnt", 8))
    expected = <<~MSG.chomp
      grainet: build error in form.gnt:8
        data-value not allowed on <div>
    MSG
    assert_equal expected, err.message
  end

  def test_suggestion_appended_after_body
    err = Grainet::CLI::BuildError.new(
      "data-key is not a bare field name.",
      at: loc("x.gnt", 4),
      suggestion: "Use `data-key=\"id\"` (no `it.` prefix, no `@`, no `.`, no `?`).",
    )
    expected = <<~MSG.chomp
      grainet: build error in x.gnt:4
        data-key is not a bare field name.
        Use `data-key="id"` (no `it.` prefix, no `@`, no `.`, no `?`).
    MSG
    assert_equal expected, err.message
  end

  def test_multiline_body_is_indented_per_line
    err = Grainet::CLI::BuildError.new("first line\nsecond line", at: loc("x.gnt", 1))
    expected = <<~MSG.chomp
      grainet: build error in x.gnt:1
        first line
        second line
    MSG
    assert_equal expected, err.message
  end

  def test_bare_string_form_passes_message_through
    err = Grainet::CLI::BuildError.new("just a message")
    assert_equal "just a message", err.message
  end

  def test_raise_with_just_string_keeps_backward_compat
    err = assert_raises(Grainet::CLI::BuildError) { raise Grainet::CLI::BuildError, "boom" }
    assert_equal "boom", err.message
  end

  def test_subclasses_inherit_formatter
    codegen_err = Grainet::CLI::Codegen::Error.new("oops", at: loc("a.gnt", 1))
    assert_includes codegen_err.message, "grainet: build error in a.gnt:1"
    assert_includes codegen_err.message, "  oops"

    compat_err = Grainet::CLI::DirectiveCompatibility::Error.new("clash", at: loc("b.gnt", 2))
    assert_includes compat_err.message, "grainet: build error in b.gnt:2"
    assert_includes compat_err.message, "  clash"
  end
end
