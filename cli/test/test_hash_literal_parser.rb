# frozen_string_literal: true

require "test_helper"

class TestHashLiteralParser < Minitest::Test
  P = Grainet::CLI::HashLiteralParser

  # ---- happy paths ------------------------------------------------

  def test_empty_hash
    assert_equal [], P.parse("{}")
    assert_equal [], P.parse("{ }")
    assert_equal [], P.parse("  {  }  ")
  end

  def test_single_bare_pair
    assert_equal [["active", "@is_active"]], P.parse("{ active: @is_active }")
  end

  def test_multiple_bare_pairs
    pairs = P.parse("{ active: @a, error: @e, loading: @l }")
    assert_equal [["active", "@a"], ["error", "@e"], ["loading", "@l"]], pairs
  end

  def test_single_quoted_kebab_key
    assert_equal [["btn-primary", "@primary"]], P.parse("{ 'btn-primary': @primary }")
  end

  def test_double_quoted_kebab_key
    assert_equal [["btn-primary", "@primary"]], P.parse('{ "btn-primary": @primary }')
  end

  def test_quoted_tailwind_variant_with_colon_in_key
    pairs = P.parse("{ 'hover:bg-blue-500': @h, 'md:text-lg': @d }")
    assert_equal [["hover:bg-blue-500", "@h"], ["md:text-lg", "@d"]], pairs
  end

  def test_quoted_bem_key
    assert_equal [["card__title--large", "@show"]], P.parse("{ 'card__title--large': @show }")
  end

  def test_quoted_tailwind_arbitrary_value_key
    assert_equal [["top-[117px]", "@t"]], P.parse("{ 'top-[117px]': @t }")
    assert_equal [["bg-[#bada55]", "@b"]], P.parse("{ 'bg-[#bada55]': @b }")
  end

  def test_mixed_bare_and_quoted
    pairs = P.parse("{ active: @a, disabled: @d, 'btn-primary': @p }")
    assert_equal [["active", "@a"], ["disabled", "@d"], ["btn-primary", "@p"]], pairs
  end

  def test_it_path_value
    assert_equal [["done", "it.done"]], P.parse("{ done: it.done }")
  end

  def test_it_value_bare
    assert_equal [["valid", "it"]], P.parse("{ valid: it }")
  end

  # ---- whitespace tolerance --------------------------------------

  def test_extra_whitespace_around_colons_and_commas
    pairs = P.parse("{   active   :   @a   ,   error  :  @e   }")
    assert_equal [["active", "@a"], ["error", "@e"]], pairs
  end

  def test_newlines_between_entries
    pairs = P.parse(<<~HASH)
      {
        active: @a,
        error: @e
      }
    HASH
    assert_equal [["active", "@a"], ["error", "@e"]], pairs
  end

  # ---- errors -----------------------------------------------------

  def test_bare_key_with_kebab_is_rejected
    err = assert_raises(P::Error) { P.parse("{ btn-primary: @p }") }
    # `btn` parses as bare ident, then `-` is unexpected at `:`-position
    assert_includes err.message, "expected"
  end

  def test_whitespace_in_quoted_key_is_rejected
    err = assert_raises(P::Error) { P.parse("{ 'btn primary': @p }") }
    assert_includes err.message, "invalid character"
  end

  def test_semicolon_in_quoted_key_is_rejected
    err = assert_raises(P::Error) { P.parse("{ 'a;b': @p }") }
    assert_includes err.message, "invalid character"
  end

  def test_control_char_in_quoted_key_is_rejected
    err = assert_raises(P::Error) { P.parse(%({ "a\x01b": @p })) }
    assert_includes err.message, "invalid character"
  end

  def test_unterminated_quote_is_rejected
    err = assert_raises(P::Error) { P.parse("{ 'btn-primary: @p }") }
    assert_includes err.message, "unterminated"
  end

  def test_missing_value_is_rejected
    assert_raises(P::Error) { P.parse("{ active: }") }
  end

  def test_missing_colon_is_rejected
    assert_raises(P::Error) { P.parse("{ active @a }") }
  end

  def test_trailing_content_after_close_brace_is_rejected
    err = assert_raises(P::Error) { P.parse("{ active: @a } junk") }
    assert_includes err.message, "trailing"
  end

  def test_missing_open_brace_is_rejected
    assert_raises(P::Error) { P.parse("active: @a }") }
  end

  def test_missing_close_brace_is_rejected
    assert_raises(P::Error) { P.parse("{ active: @a") }
  end
end
