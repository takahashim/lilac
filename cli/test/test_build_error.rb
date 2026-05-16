# frozen_string_literal: true

require "test_helper"

class TestBuildError < Minitest::Test
  BE = Grainet::CLI::BuildError

  def test_structured_form_renders_header_and_body
    err = BE.new("data-value not allowed on <div>", file: "form.gnt", line: 8)
    expected = <<~MSG.chomp
      grainet: build error in form.gnt:8
        data-value not allowed on <div>
    MSG
    assert_equal expected, err.message
  end

  def test_suggestion_appended_after_body
    err = BE.new(
      "data-key is not a bare field name.",
      file: "x.gnt", line: 4,
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
    err = BE.new("first line\nsecond line", file: "x.gnt", line: 1)
    expected = <<~MSG.chomp
      grainet: build error in x.gnt:1
        first line
        second line
    MSG
    assert_equal expected, err.message
  end

  def test_bare_string_form_passes_message_through
    err = BE.new("just a message")
    assert_equal "just a message", err.message
  end

  def test_raise_with_just_string_keeps_backward_compat
    err = assert_raises(BE) { raise BE, "boom" }
    assert_equal "boom", err.message
  end

  def test_subclasses_inherit_formatter
    codegen_err = Grainet::CLI::Codegen::Error.new("oops", file: "a.gnt", line: 1)
    assert_includes codegen_err.message, "grainet: build error in a.gnt:1"
    assert_includes codegen_err.message, "  oops"

    compat_err = Grainet::CLI::DirectiveCompatibility::Error.new("clash", file: "b.gnt", line: 2)
    assert_includes compat_err.message, "grainet: build error in b.gnt:2"
    assert_includes compat_err.message, "  clash"
  end
end
