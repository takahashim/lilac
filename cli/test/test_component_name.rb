# frozen_string_literal: true

require "test_helper"

class TestComponentName < Minitest::Test
  # ---- ruby_class -------------------------------------------------

  def test_single_word
    assert_equal "Counter", Lilac::CLI::ComponentName.new("counter").ruby_class
  end

  def test_kebab_words_become_pascal_case
    assert_equal "UserProfile", Lilac::CLI::ComponentName.new("user-profile").ruby_class
    assert_equal "ButtonGroup", Lilac::CLI::ComponentName.new("button-group").ruby_class
  end

  def test_double_dash_creates_namespace
    assert_equal "Admin::UserCard", Lilac::CLI::ComponentName.new("admin--user-card").ruby_class
    assert_equal "Top::Mid::Leaf",  Lilac::CLI::ComponentName.new("top--mid--leaf").ruby_class
  end

  def test_leading_double_dash_raises_at_construction
    assert_raises(ArgumentError) { Lilac::CLI::ComponentName.new("--foo") }
  end

  def test_trailing_double_dash_raises_at_construction
    assert_raises(ArgumentError) { Lilac::CLI::ComponentName.new("foo--") }
  end

  def test_empty_segment_raises_at_construction
    assert_raises(ArgumentError) { Lilac::CLI::ComponentName.new("foo---bar") }
  end

  # ---- each_template_name ---------------------------------------

  def test_each_template_name_uses_kebab_form
    assert_equal "llc-each-counter-llc0", Lilac::CLI::ComponentName.new("counter").each_template_name("llc0")
    assert_equal "llc-each-admin--user-card-llc3",
                 Lilac::CLI::ComponentName.new("admin--user-card").each_template_name("llc3")
  end

  # ---- value-object behaviour -----------------------------------

  def test_to_s_returns_the_kebab_form
    assert_equal "user-profile", Lilac::CLI::ComponentName.new("user-profile").to_s
  end

  def test_equality_by_kebab
    assert_equal Lilac::CLI::ComponentName.new("counter"), Lilac::CLI::ComponentName.new("counter")
    refute_equal Lilac::CLI::ComponentName.new("counter"), Lilac::CLI::ComponentName.new("ccounter")
    refute_equal Lilac::CLI::ComponentName.new("counter"), "counter" # String != ComponentName
  end

  def test_hash_matches_kebab_hash_for_Hash_keys
    h = { Lilac::CLI::ComponentName.new("counter") => :value }
    assert_equal :value, h[Lilac::CLI::ComponentName.new("counter")]
  end
end
