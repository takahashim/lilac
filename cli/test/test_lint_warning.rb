# frozen_string_literal: true

require "test_helper"

class TestLintWarning < Minitest::Test
  def loc(file, line)
    Grainet::CLI::SourceLocation.new(file: file, line: line)
  end

  def test_minimal_warning_renders_header_and_body
    w = Grainet::CLI::LintWarning.new(at: loc("x.gnt", 7), body: "Signal @foo is not declared")
    assert_equal <<~MSG.chomp, w.to_s
      grainet: lint warning in x.gnt:7
        Signal @foo is not declared
    MSG
  end

  def test_declared_list_rendered_when_present
    w = Grainet::CLI::LintWarning.new(
      at: loc("x.gnt", 3), body: "Method `foo` is not defined",
      declared_label: "Declared methods", declared: %w[bar baz],
    )
    assert_equal <<~MSG.chomp, w.to_s
      grainet: lint warning in x.gnt:3
        Method `foo` is not defined
        Declared methods: bar, baz.
    MSG
  end

  def test_empty_declared_omits_the_line
    w = Grainet::CLI::LintWarning.new(
      at: loc("x.gnt", 3), body: "...",
      declared_label: "Declared signals", declared: [],
    )
    refute_includes w.to_s, "Declared"
  end

  def test_suggestion_rendered_as_indented_line_verbatim
    # The caller is responsible for adding any framing ("Did you mean:",
    # "Use:", etc.) — LintWarning just prints what it's given.
    w = Grainet::CLI::LintWarning.new(
      at: loc("x.gnt", 5), body: "Signal @cont is not declared",
      declared_label: "Declared signals", declared: ["@count"],
      suggestion: "Did you mean: @count?",
    )
    assert_equal <<~MSG.chomp, w.to_s
      grainet: lint warning in x.gnt:5
        Signal @cont is not declared
        Declared signals: @count.
        Did you mean: @count?
    MSG
  end

  def test_nil_suggestion_omits_the_line
    w = Grainet::CLI::LintWarning.new(at: loc("x.gnt", 1), body: "abc", suggestion: nil)
    refute_includes w.to_s, "Did you mean"
  end

  def test_multiline_body_is_indented_per_line
    w = Grainet::CLI::LintWarning.new(
      at: loc("x.gnt", 2),
      body: "first line\nsecond line",
    )
    assert_equal <<~MSG.chomp, w.to_s
      grainet: lint warning in x.gnt:2
        first line
        second line
    MSG
  end
end
