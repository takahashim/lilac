# frozen_string_literal: true

require "test_helper"

class TestLintWarning < Minitest::Test
  LW = Grainet::CLI::LintWarning
  SL = Grainet::CLI::SourceLocation

  def loc(file, line)
    SL.new(file: file, line: line)
  end

  def test_minimal_warning_renders_header_and_body
    w = LW.new(at: loc("x.gnt", 7), body: "Signal @foo is not declared")
    assert_equal <<~MSG.chomp, w.to_s
      grainet: lint warning in x.gnt:7
        Signal @foo is not declared
    MSG
  end

  def test_declared_list_rendered_when_present
    w = LW.new(
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
    w = LW.new(
      at: loc("x.gnt", 3), body: "...",
      declared_label: "Declared signals", declared: [],
    )
    refute_includes w.to_s, "Declared"
  end

  def test_suggestion_rendered_with_did_you_mean
    w = LW.new(
      at: loc("x.gnt", 5), body: "Signal @cont is not declared",
      declared_label: "Declared signals", declared: ["@count"],
      suggestion: "@count",
    )
    assert_equal <<~MSG.chomp, w.to_s
      grainet: lint warning in x.gnt:5
        Signal @cont is not declared
        Declared signals: @count.
        Did you mean: @count?
    MSG
  end

  def test_nil_suggestion_omits_the_line
    w = LW.new(at: loc("x.gnt", 1), body: "...", suggestion: nil)
    refute_includes w.to_s, "Did you mean"
  end
end
