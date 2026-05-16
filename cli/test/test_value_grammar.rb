# frozen_string_literal: true

require "test_helper"

class TestValueGrammar < Minitest::Test
  VG = Grainet::CLI::ValueGrammar

  # ---- ivar? ------------------------------------------------------

  def test_ivar_matches_basic
    assert VG.ivar?("@count")
    assert VG.ivar?("@is_active")
    assert VG.ivar?("@_internal")
  end

  def test_ivar_allows_predicate_suffix
    assert VG.ivar?("@valid?")
  end

  def test_ivar_rejects_bang
    refute VG.ivar?("@save!")
  end

  def test_ivar_rejects_no_at_prefix
    refute VG.ivar?("count")
  end

  def test_ivar_rejects_dot
    refute VG.ivar?("@user.name")
  end

  def test_ivar_rejects_digit_start
    refute VG.ivar?("@1count")
  end

  # ---- it_path? ---------------------------------------------------

  def test_it_path_matches_bare_it
    assert VG.it_path?("it")
  end

  def test_it_path_matches_one_dot
    assert VG.it_path?("it.title")
    assert VG.it_path?("it.is_done")
  end

  def test_it_path_allows_predicate_field
    assert VG.it_path?("it.valid?")
  end

  def test_it_path_rejects_two_dots
    refute VG.it_path?("it.user.name")
  end

  def test_it_path_rejects_method_call
    refute VG.it_path?("it.foo()")
  end

  def test_it_path_rejects_bang
    refute VG.it_path?("it.save!")
  end

  # ---- read_value? (union of ivar / it_path) ---------------------

  def test_read_value_accepts_both_forms
    assert VG.read_value?("@count")
    assert VG.read_value?("it")
    assert VG.read_value?("it.title")
  end

  def test_read_value_rejects_arbitrary_expr
    refute VG.read_value?("@a + 1")
    refute VG.read_value?("@a.b")
    refute VG.read_value?("not @a")
  end

  # ---- method_ident? ---------------------------------------------

  def test_method_ident_matches_basic
    assert VG.method_ident?("increment")
    assert VG.method_ident?("add_todo")
    assert VG.method_ident?("_helper")
  end

  def test_method_ident_rejects_predicate
    # event handler must not be `?` — spec L99 reserves predicates for
    # read-only queries
    refute VG.method_ident?("valid?")
  end

  def test_method_ident_rejects_bang
    refute VG.method_ident?("save!")
  end

  def test_method_ident_rejects_at_prefix
    refute VG.method_ident?("@thing")
  end

  # ---- class_name? -----------------------------------------------

  def test_class_name_single_segment
    assert VG.class_name?("Counter")
    assert VG.class_name?("UserCard")
  end

  def test_class_name_namespaced
    assert VG.class_name?("Admin::UserCard")
    assert VG.class_name?("Top::Mid::Leaf")
  end

  def test_class_name_rejects_lowercase_start
    refute VG.class_name?("counter")
  end

  def test_class_name_rejects_single_colon
    refute VG.class_name?("Admin:UserCard")
  end

  # ---- ref_ident? ------------------------------------------------

  def test_ref_ident_lowercase_only
    assert VG.ref_ident?("canvas")
    assert VG.ref_ident?("submit_button")
    refute VG.ref_ident?("Canvas")
  end
end
