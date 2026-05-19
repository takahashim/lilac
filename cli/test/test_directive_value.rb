# frozen_string_literal: true

require "test_helper"

class TestDirectiveValue < Minitest::Test
  # ---- ivar parsing -----------------------------------------------

  def test_parses_basic_ivar
    v = Lilac::CLI::DirectiveValue.parse("@count")
    assert_kind_of Lilac::CLI::DirectiveValue::Ivar, v
    assert v.ivar?
    refute v.it_path?
    assert_equal "@count", v.to_s
  end

  def test_parses_predicate_suffix_ivar
    v = Lilac::CLI::DirectiveValue.parse("@valid?")
    assert v.ivar?
    assert_equal "@valid?", v.to_s
  end

  def test_strips_surrounding_whitespace
    v = Lilac::CLI::DirectiveValue.parse("  @count  ")
    assert v.ivar?
    assert_equal "@count", v.to_s
  end

  def test_rejects_bang_in_ivar
    assert_nil Lilac::CLI::DirectiveValue.parse("@save!")
  end

  def test_rejects_dotted_ivar
    assert_nil Lilac::CLI::DirectiveValue.parse("@user.name")
  end

  def test_rejects_digit_start_ivar
    assert_nil Lilac::CLI::DirectiveValue.parse("@1count")
  end

  # ---- it_path parsing -------------------------------------------

  def test_parses_bare_it
    v = Lilac::CLI::DirectiveValue.parse("it")
    assert_kind_of Lilac::CLI::DirectiveValue::ItPath, v
    refute v.ivar?
    assert v.it_path?
    assert_equal "it", v.to_s
  end

  def test_parses_one_dot_it_path
    v = Lilac::CLI::DirectiveValue.parse("it.title")
    assert v.it_path?
    assert_equal "it.title", v.to_s
  end

  def test_parses_predicate_field_it_path
    v = Lilac::CLI::DirectiveValue.parse("it.valid?")
    assert v.it_path?
  end

  def test_rejects_two_dot_it_path
    assert_nil Lilac::CLI::DirectiveValue.parse("it.user.name")
  end

  def test_rejects_method_call_it_path
    assert_nil Lilac::CLI::DirectiveValue.parse("it.foo()")
  end

  # ---- bare_ident parsing ----------------------------------------

  def test_parses_bare_ident
    # Plain identifier — field name on the current iteration item when
    # used inside a data-each body.
    v = Lilac::CLI::DirectiveValue.parse("description")
    assert_kind_of Lilac::CLI::DirectiveValue::BareIdent, v
    refute v.ivar?
    refute v.it_path?
    assert v.bare_ident?
    assert_equal "description", v.to_s
  end

  def test_parses_predicate_suffix_bare_ident
    v = Lilac::CLI::DirectiveValue.parse("valid?")
    assert v.bare_ident?
    assert_equal "valid?", v.to_s
  end

  def test_it_takes_precedence_over_bare_ident
    # `it` alone matches IT_PATH before BARE_IDENT.
    v = Lilac::CLI::DirectiveValue.parse("it")
    assert v.it_path?
    refute v.bare_ident?
  end

  def test_rejects_dotted_bare_ident
    assert_nil Lilac::CLI::DirectiveValue.parse("user.name")
  end

  # ---- invalid forms ---------------------------------------------

  def test_returns_nil_on_arbitrary_expression
    assert_nil Lilac::CLI::DirectiveValue.parse("@a + 1")
    assert_nil Lilac::CLI::DirectiveValue.parse("not @a")
    # Numeric prefix is not an identifier.
    assert_nil Lilac::CLI::DirectiveValue.parse("1bad")
  end

  # ---- polymorphic codegen helpers -------------------------------

  def test_ivar_reactive_read_appends_dot_value
    v = Lilac::CLI::DirectiveValue.parse("@count")
    assert_equal "@count.value", v.reactive_read
  end

  def test_it_path_reactive_read_returns_raw
    v = Lilac::CLI::DirectiveValue.parse("it.title")
    assert_equal "it.title", v.reactive_read
  end

  def test_ivar_bind_source_is_raw_signal
    v = Lilac::CLI::DirectiveValue.parse("@count")
    assert_equal "@count", v.bind_source
  end

  def test_it_path_bind_source_wraps_in_computed
    v = Lilac::CLI::DirectiveValue.parse("it.title")
    assert_equal "computed { it.title }", v.bind_source
  end

  def test_bare_ident_reactive_read_resolves_against_it
    v = Lilac::CLI::DirectiveValue.parse("title")
    assert_equal "it.title", v.reactive_read
  end

  def test_bare_ident_bind_source_wraps_in_computed
    v = Lilac::CLI::DirectiveValue.parse("title")
    assert_equal "computed { it.title }", v.bind_source
  end

  # ---- signal_ref (data-bind codegen) ----------------------------

  def test_ivar_signal_ref_returns_raw_signal_without_value_unwrap
    # bind_input wants the Signal object itself (it calls .value
    # inside its own effect), so signal_ref skips the .value suffix
    # that reactive_read appends.
    v = Lilac::CLI::DirectiveValue.parse("@qty")
    assert_equal "@qty", v.signal_ref
  end

  def test_bare_ident_signal_ref_reads_item_field
    # Inside a data-each bind_list block, `it` is the iteration variable
    # and `it.qty` resolves to the per-row Signal stored on the item.
    v = Lilac::CLI::DirectiveValue.parse("qty")
    assert_equal "it.qty", v.signal_ref
  end

  # ---- inspect / interpolation -----------------------------------

  def test_inspect_returns_quoted_raw_for_error_messages
    v = Lilac::CLI::DirectiveValue.parse("@count")
    assert_equal "\"@count\"", v.inspect
  end

  def test_to_s_interpolates_as_raw
    v = Lilac::CLI::DirectiveValue.parse("@count")
    assert_equal "value=@count", "value=#{v}"
  end
end
