# frozen_string_literal: true

require "test_helper"

class TestGrammar < Minitest::Test
  # `@ivar` / bare-ident value-shape predicates now live on
  # Lilac::Directives::Value.parse — see directives/test_value.rb.

  # ---- method_ident? ---------------------------------------------

  def test_method_ident_matches_basic
    assert Lilac::Directives::Grammar.method_ident?("increment")
    assert Lilac::Directives::Grammar.method_ident?("add_todo")
    assert Lilac::Directives::Grammar.method_ident?("_helper")
  end

  def test_method_ident_rejects_predicate
    # event handler must not be `?` — spec L99 reserves predicates for
    # read-only queries
    refute Lilac::Directives::Grammar.method_ident?("valid?")
  end

  def test_method_ident_rejects_bang
    refute Lilac::Directives::Grammar.method_ident?("save!")
  end

  def test_method_ident_rejects_at_prefix
    refute Lilac::Directives::Grammar.method_ident?("@thing")
  end

  # ---- class_name? -----------------------------------------------

  def test_class_name_single_segment
    assert Lilac::Directives::Grammar.class_name?("Counter")
    assert Lilac::Directives::Grammar.class_name?("UserCard")
  end

  def test_class_name_namespaced
    assert Lilac::Directives::Grammar.class_name?("Admin::UserCard")
    assert Lilac::Directives::Grammar.class_name?("Top::Mid::Leaf")
  end

  def test_class_name_rejects_lowercase_start
    refute Lilac::Directives::Grammar.class_name?("counter")
  end

  def test_class_name_rejects_single_colon
    refute Lilac::Directives::Grammar.class_name?("Admin:UserCard")
  end

  # ---- ref_ident? ------------------------------------------------

  def test_ref_ident_lowercase_only
    assert Lilac::Directives::Grammar.ref_ident?("canvas")
    assert Lilac::Directives::Grammar.ref_ident?("submit_button")
    refute Lilac::Directives::Grammar.ref_ident?("Canvas")
  end

  # ---- kebab_name? -----------------------------------------------

  def test_kebab_name_accepts_letter_only
    assert Lilac::Directives::Grammar.kebab_name?("href")
    assert Lilac::Directives::Grammar.kebab_name?("color")
  end

  def test_kebab_name_accepts_hyphenated
    assert Lilac::Directives::Grammar.kebab_name?("theme-color")
    assert Lilac::Directives::Grammar.kebab_name?("data-id")
  end

  def test_kebab_name_accepts_digit_in_middle
    assert Lilac::Directives::Grammar.kebab_name?("h1-size")
  end

  def test_kebab_name_rejects_uppercase
    refute Lilac::Directives::Grammar.kebab_name?("Color")
    refute Lilac::Directives::Grammar.kebab_name?("themeColor")
  end

  def test_kebab_name_rejects_digit_start
    refute Lilac::Directives::Grammar.kebab_name?("3d-effect")
  end

  def test_kebab_name_rejects_underscore
    refute Lilac::Directives::Grammar.kebab_name?("theme_color")
  end

  def test_kebab_name_rejects_leading_hyphen
    refute Lilac::Directives::Grammar.kebab_name?("-theme-color")
    refute Lilac::Directives::Grammar.kebab_name?("--theme")
  end

  # ---- banned_attr? ----------------------------------------------

  def test_banned_attr_matches_on_handlers
    assert Lilac::Directives::Grammar.banned_attr?("onclick")
    assert Lilac::Directives::Grammar.banned_attr?("onload")
    assert Lilac::Directives::Grammar.banned_attr?("onmouseover")
  end

  def test_banned_attr_matches_srcdoc_and_style
    assert Lilac::Directives::Grammar.banned_attr?("srcdoc")
    assert Lilac::Directives::Grammar.banned_attr?("style")
  end

  def test_banned_attr_does_not_match_safe_names
    refute Lilac::Directives::Grammar.banned_attr?("href")
    refute Lilac::Directives::Grammar.banned_attr?("data-id")
    refute Lilac::Directives::Grammar.banned_attr?("on")             # missing trailing handler suffix
    refute Lilac::Directives::Grammar.banned_attr?("onclick-extra")  # not pure on[a-z]+
  end
end
