# frozen_string_literal: true

require "test_helper"

class TestComponentName < Minitest::Test
  CN = Grainet::CLI::ComponentName

  def test_single_word
    assert_equal "Counter", CN.to_ruby_class("counter")
  end

  def test_kebab_words_become_pascal_case
    assert_equal "UserProfile", CN.to_ruby_class("user-profile")
    assert_equal "ButtonGroup", CN.to_ruby_class("button-group")
  end

  def test_double_dash_creates_namespace
    assert_equal "Admin::UserCard", CN.to_ruby_class("admin--user-card")
    assert_equal "Top::Mid::Leaf",  CN.to_ruby_class("top--mid--leaf")
  end

  def test_leading_double_dash_raises
    assert_raises(ArgumentError) { CN.to_ruby_class("--foo") }
  end

  def test_trailing_double_dash_raises
    assert_raises(ArgumentError) { CN.to_ruby_class("foo--") }
  end

  def test_empty_segment_raises
    assert_raises(ArgumentError) { CN.to_ruby_class("foo---bar") }
  end
end
