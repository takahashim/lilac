# frozen_string_literal: true

require "test_helper"

class TestValue < Minitest::Test
  # ---- ivar parsing -----------------------------------------------

  def test_parses_basic_ivar
    v = Lilac::Directives::Value.parse("@count")
    assert_kind_of Lilac::Directives::Value::Ivar, v
    assert v.ivar?
    refute v.bare_ident?
    assert_equal "@count", v.to_s
  end

  def test_parses_predicate_suffix_ivar
    v = Lilac::Directives::Value.parse("@valid?")
    assert v.ivar?
    assert_equal "@valid?", v.to_s
  end

  def test_strips_surrounding_whitespace
    v = Lilac::Directives::Value.parse("  @count  ")
    assert v.ivar?
    assert_equal "@count", v.to_s
  end

  def test_rejects_bang_in_ivar
    assert_nil Lilac::Directives::Value.parse("@save!")
  end

  def test_rejects_dotted_ivar
    assert_nil Lilac::Directives::Value.parse("@user.name")
  end

  def test_rejects_digit_start_ivar
    assert_nil Lilac::Directives::Value.parse("@1count")
  end

  # ---- bare_ident parsing ----------------------------------------

  def test_parses_bare_ident
    # Plain identifier — field name on the current iteration item when
    # used inside a data-each body.
    v = Lilac::Directives::Value.parse("description")
    assert_kind_of Lilac::Directives::Value::BareIdent, v
    refute v.ivar?
    assert v.bare_ident?
    assert_equal "description", v.to_s
  end

  def test_parses_predicate_suffix_bare_ident
    v = Lilac::Directives::Value.parse("valid?")
    assert v.bare_ident?
    assert_equal "valid?", v.to_s
  end

  def test_rejects_dotted_bare_ident
    assert_nil Lilac::Directives::Value.parse("user.name")
  end

  # ---- invalid forms ---------------------------------------------

  def test_returns_nil_on_arbitrary_expression
    assert_nil Lilac::Directives::Value.parse("@a + 1")
    assert_nil Lilac::Directives::Value.parse("not @a")
    # Numeric prefix is not an identifier.
    assert_nil Lilac::Directives::Value.parse("1bad")
  end

  # ---- inspect / interpolation -----------------------------------

  def test_inspect_returns_quoted_raw_for_error_messages
    v = Lilac::Directives::Value.parse("@count")
    assert_equal "\"@count\"", v.inspect
  end

  def test_to_s_interpolates_as_raw
    v = Lilac::Directives::Value.parse("@count")
    assert_equal "value=@count", "value=#{v}"
  end
end
