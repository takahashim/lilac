# frozen_string_literal: true

require "test_helper"

class TestClassParser < Minitest::Test
  # ---- happy paths ------------------------------------------------

  def test_empty_hash
    assert_equal [], Lilac::Directives::ClassParser.parse("{}")
    assert_equal [], Lilac::Directives::ClassParser.parse("{ }")
    assert_equal [], Lilac::Directives::ClassParser.parse("  {  }  ")
  end

  def test_single_bare_pair
    assert_equal [["active", "@is_active"]], Lilac::Directives::ClassParser.parse("{ active: @is_active }")
  end

  def test_multiple_bare_pairs
    pairs = Lilac::Directives::ClassParser.parse("{ active: @a, error: @e, loading: @l }")
    assert_equal [["active", "@a"], ["error", "@e"], ["loading", "@l"]], pairs
  end

  def test_single_quoted_kebab_key
    assert_equal [["btn-primary", "@primary"]], Lilac::Directives::ClassParser.parse("{ 'btn-primary': @primary }")
  end

  def test_double_quoted_kebab_key
    assert_equal [["btn-primary", "@primary"]], Lilac::Directives::ClassParser.parse('{ "btn-primary": @primary }')
  end

  def test_quoted_tailwind_variant_with_colon_in_key
    pairs = Lilac::Directives::ClassParser.parse("{ 'hover:bg-blue-500': @h, 'md:text-lg': @d }")
    assert_equal [["hover:bg-blue-500", "@h"], ["md:text-lg", "@d"]], pairs
  end

  def test_quoted_bem_key
    assert_equal [["card__title--large", "@show"]], Lilac::Directives::ClassParser.parse("{ 'card__title--large': @show }")
  end

  def test_quoted_tailwind_arbitrary_value_key
    assert_equal [["top-[117px]", "@t"]], Lilac::Directives::ClassParser.parse("{ 'top-[117px]': @t }")
    assert_equal [["bg-[#bada55]", "@b"]], Lilac::Directives::ClassParser.parse("{ 'bg-[#bada55]': @b }")
  end

  def test_mixed_bare_and_quoted
    pairs = Lilac::Directives::ClassParser.parse("{ active: @a, disabled: @d, 'btn-primary': @p }")
    assert_equal [["active", "@a"], ["disabled", "@d"], ["btn-primary", "@p"]], pairs
  end

  def test_bare_ident_value
    # Bare-ident values reference the current iteration item's field;
    # the parser keeps them as raw strings — grammar checking happens
    # in Codegen.emit_class.
    assert_equal [["done", "done"]], Lilac::Directives::ClassParser.parse("{ done: done }")
  end

  # ---- whitespace tolerance --------------------------------------

  def test_extra_whitespace_around_colons_and_commas
    pairs = Lilac::Directives::ClassParser.parse("{   active   :   @a   ,   error  :  @e   }")
    assert_equal [["active", "@a"], ["error", "@e"]], pairs
  end

  def test_newlines_between_entries
    pairs = Lilac::Directives::ClassParser.parse(<<~HASH)
      {
        active: @a,
        error: @e
      }
    HASH
    assert_equal [["active", "@a"], ["error", "@e"]], pairs
  end

  # ---- errors -----------------------------------------------------

  def test_bare_key_with_kebab_is_rejected
    err = assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ btn-primary: @p }") }
    # `btn` parses as bare ident, then `-` is unexpected at `:`-position
    assert_includes err.message, "expected"
  end

  def test_whitespace_in_quoted_key_is_rejected
    err = assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ 'btn primary': @p }") }
    assert_includes err.message, "invalid character"
  end

  def test_semicolon_in_quoted_key_is_rejected
    err = assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ 'a;b': @p }") }
    assert_includes err.message, "invalid character"
  end

  def test_control_char_in_quoted_key_is_rejected
    err = assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse(%({ "a\x01b": @p })) }
    assert_includes err.message, "invalid character"
  end

  def test_unterminated_quote_is_rejected
    err = assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ 'btn-primary: @p }") }
    assert_includes err.message, "unterminated"
  end

  def test_missing_value_is_rejected
    assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ active: }") }
  end

  def test_missing_colon_is_rejected
    assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ active @a }") }
  end

  def test_trailing_content_after_close_brace_is_rejected
    err = assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ active: @a } junk") }
    assert_includes err.message, "trailing"
  end

  def test_missing_open_brace_is_rejected
    assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("active: @a }") }
  end

  def test_missing_close_brace_is_rejected
    assert_raises(Lilac::Directives::ClassParser::Error) { Lilac::Directives::ClassParser.parse("{ active: @a") }
  end
end
