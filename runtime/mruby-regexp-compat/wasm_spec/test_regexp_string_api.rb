# Further mruby-regexp-compat tests — String methods that take
# Regexp arguments, inline flag groups, pattern error handling,
# and common backref idioms.

Spec.describe "String#=~ with Regexp" do
  Spec.assert "returns match position" do
    Spec.assert_equal 6, "hello world" =~ /world/
  end

  Spec.assert "returns nil on no match" do
    Spec.assert_true(("abc" =~ /xyz/).nil?)
  end

  Spec.assert "sets $~ on match" do
    "abc" =~ /b/
    Spec.assert_equal "b", $~[0]
  end
end

Spec.describe "String#match and String#match?" do
  Spec.assert "String#match returns MatchData" do
    md = "hello".match(/(\w+)/)
    Spec.assert_equal "hello", md[0]
  end

  Spec.assert "String#match returns nil on no match" do
    Spec.assert_true("abc".match(/xyz/).nil?)
  end

  Spec.assert "String#match? returns true/false (no MatchData alloc)" do
    Spec.assert_true "abc".match?(/b/)
    Spec.assert_false "abc".match?(/z/)
  end

  Spec.assert "String#match? does not set $~" do
    /existing/ =~ "existing"  # set $~ to known state
    prev = $~
    "abc".match?(/b/)
    Spec.assert_true $~.equal?(prev)
  end
end

# KNOWN DIVERGENCE: String methods that accept Regexp in MRI do NOT
# accept Regexp in mruby-regexp-compat — they raise TypeError because
# they expect String/Integer only:
#   - String#index(Regexp)         → TypeError: Regexp cannot be converted to String
#   - String#index(Regexp, offset) → same
#   - String#rindex(Regexp)        → same
#   - String#partition(Regexp)     → TypeError
#   - String#rpartition(Regexp)    → TypeError
#   - String#[](Regexp)            → TypeError: Regexp cannot be converted to Integer
#   - String#[](Regexp, capture)   → same
#   - String#slice(Regexp)         → same
# Workaround: use regex_obj.match(str) and inspect the MatchData.
#
# Spec.describe "String#index / #rindex with Regexp"           ... 4 skipped
# Spec.describe "String#partition / #rpartition with Regexp"   ... 3 skipped
# Spec.describe "String#[] / #slice with Regexp"               ... 5 skipped

# KNOWN HANG / DoS BUG: inline flag groups (?i:...), (?m:...),
# (?x:...), (?-i:...) cause the regex compiler to enter an infinite
# loop. The wasm runtime hangs at 100% CPU and must be killed.
# MRI: these are standard regex syntax, supported everywhere.
# Workaround: apply flags to the whole regex (/.../i) or use
# Regexp.new(pattern, flags).
#
# Spec.describe "Regexp inline flag groups"
#   Spec.assert "(?i:...) case-insensitive group only" do
#     Spec.assert_true(!!(/(?i:abc)/.match("ABC")))   # HANGS
#   end
#   ... 4 more skipped

Spec.describe "Regexp pattern syntax errors" do
  Spec.assert "unclosed paren raises RegexpError" do
    Spec.assert_raises(RegexpError) { Regexp.new("(abc") }
  end

  Spec.assert "unclosed character class raises RegexpError" do
    Spec.assert_raises(RegexpError) { Regexp.new("[abc") }
  end

  Spec.assert "unclosed group with alternation raises RegexpError" do
    Spec.assert_raises(RegexpError) { Regexp.new("(a|b") }
  end

  # KNOWN HANG / DoS BUG: a regex with a LEADING quantifier — *abc,
  # ?abc, +abc — causes the compiler to enter an infinite loop.
  # MRI raises RegexpError("target of repeat operator is not specified").
  # This is a DoS vulnerability if user-controlled patterns reach
  # Regexp.new without prior validation.
  #
  # Spec.assert "lone quantifier raises RegexpError" do
  #   Spec.assert_raises(RegexpError) { Regexp.new("*abc") }   # HANGS
  # end

  Spec.assert "invalid range {3,2} silently accepts" do
    # MRI raises RegexpError when min > max.
    # mruby-regexp-compat compiles without raising — KNOWN DIVERGENCE.
    Spec.assert_true Regexp.new("a{3,2}").is_a?(Regexp)
  end
end

Spec.describe "Backreference + quantifier idioms" do
  Spec.assert "(\\w)\\1+ matches repeated chars" do
    md = /(\w)\1+/.match("aabbccc")
    Spec.assert_equal "aa", md[0]
    Spec.assert_equal "a", md[1]
  end

  Spec.assert "HTML-like balanced tag <(\\w+)>.*</\\1>" do
    md = /<(\w+)>.*<\/\1>/.match("<div>hi</div>")
    Spec.assert_equal "<div>hi</div>", md[0]
    Spec.assert_equal "div", md[1]
  end

  Spec.assert "backref fails when tag mismatch" do
    Spec.assert_true(/<(\w+)>.*<\/\1>/.match("<div>hi</span>").nil?)
  end
end

Spec.describe "Character class with escapes" do
  Spec.assert "[\\n\\t] matches newline/tab" do
    Spec.assert_true(!!(/[\n\t]/.match("\n")))
    Spec.assert_true(!!(/[\n\t]/.match("\t")))
    Spec.assert_true(/[\n\t]/.match("x").nil?)
  end

  Spec.assert "[\\\\] matches literal backslash" do
    Spec.assert_true(!!(/[\\]/.match("\\")))
  end

  Spec.assert "[\\d] is equivalent to \\d" do
    Spec.assert_equal "5", /[\d]/.match("a5b")[0]
  end

  Spec.assert "[^\\d] negated digit class" do
    Spec.assert_equal "a", /[^\d]/.match("5a")[0]
  end

  Spec.assert "[\\w\\d] union of word and digit (redundant)" do
    Spec.assert_true(!!(/[\w\d]/.match("a")))
    Spec.assert_true(!!(/[\w\d]/.match("5")))
  end
end

Spec.describe "Quantifier zero-bound edge cases" do
  # KNOWN BUG: a{0} should match empty (zero repetitions, success).
  # MRI: /a{0}/.match("xyz")[0] == "".
  # mruby-regexp-compat: returns nil — doesn't match anything.
  # Same for a{0,N} when no a is present: should match empty (return ""),
  # mruby returns nil.
  # Spec.assert "a{0} matches empty (no a)" do
  #   md = /a{0}/.match("xyz")
  #   Spec.assert_equal "", md[0]
  # end
  # Spec.assert "a{0,1} matches empty when no a" do
  #   Spec.assert_equal "", /a{0,1}/.match("xyz")[0]
  # end

  Spec.assert "a{0,1} matches single a when present" do
    Spec.assert_equal "a", /a{0,1}/.match("abc")[0]
  end

  Spec.assert "{n,n} same as {n}" do
    Spec.assert_equal "aaa", /a{3,3}/.match("aaaaa")[0]
  end
end

Spec.describe "Regexp.new options forms" do
  Spec.assert "Regexp.new with integer options" do
    re = Regexp.new("abc", Regexp::IGNORECASE)
    Spec.assert_true(!!(re.match("ABC")))
  end

  Spec.assert "Regexp.new with multiple integer options OR'd" do
    re = Regexp.new("a.b", Regexp::IGNORECASE | Regexp::MULTILINE)
    Spec.assert_true(!!(re.match("A\nB")))
  end

  Spec.assert "Regexp.new with string flags 'im'" do
    re = Regexp.new("a.b", "im")
    Spec.assert_true(!!(re.match("A\nB")))
  end

  Spec.assert "Regexp.new with nil options" do
    re = Regexp.new("abc", nil)
    Spec.assert_true(!!(re.match("abc")))
    Spec.assert_true(re.match("ABC").nil?)
  end
end

Spec.describe "Regexp metadata methods" do
  Spec.assert "Regexp#source returns pattern text" do
    Spec.assert_equal "ab.c", /ab.c/.source
  end

  Spec.assert "Regexp#options returns flag integer" do
    Spec.assert_equal Regexp::IGNORECASE, /x/i.options & Regexp::IGNORECASE
  end

  Spec.assert "Regexp#casefold? for /i" do
    Spec.assert_true(/x/i.casefold?)
    Spec.assert_false(/x/.casefold?)
  end

  Spec.assert "Regexp#== compares source and options" do
    Spec.assert_true(/abc/ == /abc/)
    Spec.assert_false(/abc/ == /abd/)
    Spec.assert_false(/abc/ == /abc/i)
  end

  Spec.assert "Regexp#hash equal regexps have equal hash" do
    Spec.assert_equal(/abc/.hash, /abc/.hash)
  end

  Spec.assert "Regexp#inspect returns /.../" do
    Spec.assert_equal "/abc/", /abc/.inspect
    Spec.assert_equal "/abc/i", /abc/i.inspect
  end

  Spec.assert "Regexp#to_s returns (?...:source) form" do
    Spec.assert_true(/abc/.to_s.include?("abc"))
  end
end

Spec.describe "$1 through $9 with multiple captures" do
  Spec.assert "$1..$9 populated for 9-group match" do
    /(\d)(\d)(\d)(\d)(\d)(\d)(\d)(\d)(\d)/ =~ "123456789"
    Spec.assert_equal "1", $1
    Spec.assert_equal "5", $5
    Spec.assert_equal "9", $9
  end

  Spec.assert "$10+ via $~[10]" do
    /(\d)(\d)(\d)(\d)(\d)(\d)(\d)(\d)(\d)(\d)/ =~ "1234567890"
    Spec.assert_equal "0", $~[10]
  end
end

Spec.describe "Empty group and degenerate patterns" do
  Spec.assert "() empty capturing group" do
    md = /()/.match("abc")
    Spec.assert_equal "", md[0]
    Spec.assert_equal "", md[1]
  end

  Spec.assert "(?:) empty non-capturing group" do
    md = /(?:)/.match("abc")
    Spec.assert_equal "", md[0]
  end

  Spec.assert "(?:a|) alternation with empty alternative" do
    Spec.assert_equal "a", /(?:a|)/.match("abc")[0]
    Spec.assert_equal "", /(?:a|)/.match("xyz")[0]
  end

  # KNOWN DIVERGENCE: leftmost alternative should win for empty/a
  # match. MRI: /(?:|a)/.match("abc")[0] == "" (empty alt wins).
  # mruby-regexp-compat: returns "a" (matches second alternative
  # instead). Related to the longest-match bias seen in earlier
  # /ab|abc/ test.
  # Spec.assert "(?:|a) leading empty alternative" do
  #   Spec.assert_equal "", /(?:|a)/.match("abc")[0]
  # end
end

Spec.describe "Anchored patterns in alternation" do
  Spec.assert "^a|b$ — operator precedence" do
    Spec.assert_true(!!(/^a|b$/.match("apple")))   # matches ^a
    Spec.assert_true(!!(/^a|b$/.match("crab")))    # matches b$
    Spec.assert_true(/^a|b$/.match("xax").nil?)    # no anchor satisfied
  end
end

Spec.describe "Lookahead with quantifier" do
  Spec.assert "(?=...) followed by literal" do
    md = /(?=abc)ab/.match("abc")
    Spec.assert_equal "ab", md[0]
  end

  Spec.assert "nested lookahead" do
    Spec.assert_true(!!(/(?=a(?=b))/.match("ab")))
    Spec.assert_true(/(?=a(?=b))/.match("ac").nil?)
  end
end
