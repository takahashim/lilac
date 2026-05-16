# frozen_string_literal: true

require "test_helper"

class TestValueGrammar < Minitest::Test
  # ---- ivar? ------------------------------------------------------

  def test_ivar_matches_basic
    assert Grainet::CLI::ValueGrammar.ivar?("@count")
    assert Grainet::CLI::ValueGrammar.ivar?("@is_active")
    assert Grainet::CLI::ValueGrammar.ivar?("@_internal")
  end

  def test_ivar_allows_predicate_suffix
    assert Grainet::CLI::ValueGrammar.ivar?("@valid?")
  end

  def test_ivar_rejects_bang
    refute Grainet::CLI::ValueGrammar.ivar?("@save!")
  end

  def test_ivar_rejects_no_at_prefix
    refute Grainet::CLI::ValueGrammar.ivar?("count")
  end

  def test_ivar_rejects_dot
    refute Grainet::CLI::ValueGrammar.ivar?("@user.name")
  end

  def test_ivar_rejects_digit_start
    refute Grainet::CLI::ValueGrammar.ivar?("@1count")
  end

  # ---- it_path? ---------------------------------------------------

  def test_it_path_matches_bare_it
    assert Grainet::CLI::ValueGrammar.it_path?("it")
  end

  def test_it_path_matches_one_dot
    assert Grainet::CLI::ValueGrammar.it_path?("it.title")
    assert Grainet::CLI::ValueGrammar.it_path?("it.is_done")
  end

  def test_it_path_allows_predicate_field
    assert Grainet::CLI::ValueGrammar.it_path?("it.valid?")
  end

  def test_it_path_rejects_two_dots
    refute Grainet::CLI::ValueGrammar.it_path?("it.user.name")
  end

  def test_it_path_rejects_method_call
    refute Grainet::CLI::ValueGrammar.it_path?("it.foo()")
  end

  def test_it_path_rejects_bang
    refute Grainet::CLI::ValueGrammar.it_path?("it.save!")
  end

  # ---- read_value? (union of ivar / it_path) ---------------------

  def test_read_value_accepts_both_forms
    assert Grainet::CLI::ValueGrammar.read_value?("@count")
    assert Grainet::CLI::ValueGrammar.read_value?("it")
    assert Grainet::CLI::ValueGrammar.read_value?("it.title")
  end

  def test_read_value_rejects_arbitrary_expr
    refute Grainet::CLI::ValueGrammar.read_value?("@a + 1")
    refute Grainet::CLI::ValueGrammar.read_value?("@a.b")
    refute Grainet::CLI::ValueGrammar.read_value?("not @a")
  end

  # ---- method_ident? ---------------------------------------------

  def test_method_ident_matches_basic
    assert Grainet::CLI::ValueGrammar.method_ident?("increment")
    assert Grainet::CLI::ValueGrammar.method_ident?("add_todo")
    assert Grainet::CLI::ValueGrammar.method_ident?("_helper")
  end

  def test_method_ident_rejects_predicate
    # event handler must not be `?` — spec L99 reserves predicates for
    # read-only queries
    refute Grainet::CLI::ValueGrammar.method_ident?("valid?")
  end

  def test_method_ident_rejects_bang
    refute Grainet::CLI::ValueGrammar.method_ident?("save!")
  end

  def test_method_ident_rejects_at_prefix
    refute Grainet::CLI::ValueGrammar.method_ident?("@thing")
  end

  # ---- class_name? -----------------------------------------------

  def test_class_name_single_segment
    assert Grainet::CLI::ValueGrammar.class_name?("Counter")
    assert Grainet::CLI::ValueGrammar.class_name?("UserCard")
  end

  def test_class_name_namespaced
    assert Grainet::CLI::ValueGrammar.class_name?("Admin::UserCard")
    assert Grainet::CLI::ValueGrammar.class_name?("Top::Mid::Leaf")
  end

  def test_class_name_rejects_lowercase_start
    refute Grainet::CLI::ValueGrammar.class_name?("counter")
  end

  def test_class_name_rejects_single_colon
    refute Grainet::CLI::ValueGrammar.class_name?("Admin:UserCard")
  end

  # ---- ref_ident? ------------------------------------------------

  def test_ref_ident_lowercase_only
    assert Grainet::CLI::ValueGrammar.ref_ident?("canvas")
    assert Grainet::CLI::ValueGrammar.ref_ident?("submit_button")
    refute Grainet::CLI::ValueGrammar.ref_ident?("Canvas")
  end

  # ---- kebab_name? -----------------------------------------------

  def test_kebab_name_accepts_letter_only
    assert Grainet::CLI::ValueGrammar.kebab_name?("href")
    assert Grainet::CLI::ValueGrammar.kebab_name?("color")
  end

  def test_kebab_name_accepts_hyphenated
    assert Grainet::CLI::ValueGrammar.kebab_name?("theme-color")
    assert Grainet::CLI::ValueGrammar.kebab_name?("data-id")
  end

  def test_kebab_name_accepts_digit_in_middle
    assert Grainet::CLI::ValueGrammar.kebab_name?("h1-size")
  end

  def test_kebab_name_rejects_uppercase
    refute Grainet::CLI::ValueGrammar.kebab_name?("Color")
    refute Grainet::CLI::ValueGrammar.kebab_name?("themeColor")
  end

  def test_kebab_name_rejects_digit_start
    refute Grainet::CLI::ValueGrammar.kebab_name?("3d-effect")
  end

  def test_kebab_name_rejects_underscore
    refute Grainet::CLI::ValueGrammar.kebab_name?("theme_color")
  end

  def test_kebab_name_rejects_leading_hyphen
    refute Grainet::CLI::ValueGrammar.kebab_name?("-theme-color")
    refute Grainet::CLI::ValueGrammar.kebab_name?("--theme")
  end

  # ---- banned_attr? ----------------------------------------------

  def test_banned_attr_matches_on_handlers
    assert Grainet::CLI::ValueGrammar.banned_attr?("onclick")
    assert Grainet::CLI::ValueGrammar.banned_attr?("onload")
    assert Grainet::CLI::ValueGrammar.banned_attr?("onmouseover")
  end

  def test_banned_attr_matches_srcdoc_and_style
    assert Grainet::CLI::ValueGrammar.banned_attr?("srcdoc")
    assert Grainet::CLI::ValueGrammar.banned_attr?("style")
  end

  def test_banned_attr_does_not_match_safe_names
    refute Grainet::CLI::ValueGrammar.banned_attr?("href")
    refute Grainet::CLI::ValueGrammar.banned_attr?("data-id")
    refute Grainet::CLI::ValueGrammar.banned_attr?("on")             # missing trailing handler suffix
    refute Grainet::CLI::ValueGrammar.banned_attr?("onclick-extra")  # not pure on[a-z]+
  end
end
