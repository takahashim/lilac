# frozen_string_literal: true

require "test_helper"

class TestDirectiveValue < Minitest::Test
  # ---- ivar parsing -----------------------------------------------

  def test_parses_basic_ivar
    v = Grainet::CLI::DirectiveValue.parse("@count")
    assert_kind_of Grainet::CLI::DirectiveValue::Ivar, v
    assert v.ivar?
    refute v.it_path?
    assert_equal "@count", v.to_s
  end

  def test_parses_predicate_suffix_ivar
    v = Grainet::CLI::DirectiveValue.parse("@valid?")
    assert v.ivar?
    assert_equal "@valid?", v.to_s
  end

  def test_strips_surrounding_whitespace
    v = Grainet::CLI::DirectiveValue.parse("  @count  ")
    assert v.ivar?
    assert_equal "@count", v.to_s
  end

  def test_rejects_bang_in_ivar
    assert_nil Grainet::CLI::DirectiveValue.parse("@save!")
  end

  def test_rejects_dotted_ivar
    assert_nil Grainet::CLI::DirectiveValue.parse("@user.name")
  end

  def test_rejects_digit_start_ivar
    assert_nil Grainet::CLI::DirectiveValue.parse("@1count")
  end

  # ---- it_path parsing -------------------------------------------

  def test_parses_bare_it
    v = Grainet::CLI::DirectiveValue.parse("it")
    assert_kind_of Grainet::CLI::DirectiveValue::ItPath, v
    refute v.ivar?
    assert v.it_path?
    assert_equal "it", v.to_s
  end

  def test_parses_one_dot_it_path
    v = Grainet::CLI::DirectiveValue.parse("it.title")
    assert v.it_path?
    assert_equal "it.title", v.to_s
  end

  def test_parses_predicate_field_it_path
    v = Grainet::CLI::DirectiveValue.parse("it.valid?")
    assert v.it_path?
  end

  def test_rejects_two_dot_it_path
    assert_nil Grainet::CLI::DirectiveValue.parse("it.user.name")
  end

  def test_rejects_method_call_it_path
    assert_nil Grainet::CLI::DirectiveValue.parse("it.foo()")
  end

  # ---- invalid forms ---------------------------------------------

  def test_returns_nil_on_arbitrary_expression
    assert_nil Grainet::CLI::DirectiveValue.parse("@a + 1")
    assert_nil Grainet::CLI::DirectiveValue.parse("not @a")
    assert_nil Grainet::CLI::DirectiveValue.parse("foo")
  end

  # ---- polymorphic codegen helpers -------------------------------

  def test_ivar_reactive_read_appends_dot_value
    v = Grainet::CLI::DirectiveValue.parse("@count")
    assert_equal "@count.value", v.reactive_read
  end

  def test_it_path_reactive_read_returns_raw
    v = Grainet::CLI::DirectiveValue.parse("it.title")
    assert_equal "it.title", v.reactive_read
  end

  def test_ivar_bind_source_is_raw_signal
    v = Grainet::CLI::DirectiveValue.parse("@count")
    assert_equal "@count", v.bind_source
  end

  def test_it_path_bind_source_wraps_in_computed
    v = Grainet::CLI::DirectiveValue.parse("it.title")
    assert_equal "computed { it.title }", v.bind_source
  end

  # ---- inspect / interpolation -----------------------------------

  def test_inspect_returns_quoted_raw_for_error_messages
    v = Grainet::CLI::DirectiveValue.parse("@count")
    assert_equal "\"@count\"", v.inspect
  end

  def test_to_s_interpolates_as_raw
    v = Grainet::CLI::DirectiveValue.parse("@count")
    assert_equal "value=@count", "value=#{v}"
  end
end
