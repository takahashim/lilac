class String
  # Capture the C-defined String#split under `__split` before the override
  # below replaces it, so the override can delegate non-regexp patterns
  # back to the core implementation.
  alias __split split

  def match(re, pos = 0)
    re = Regexp.new(re) if re.is_a?(String)
    re.match(self, pos)
  end

  def match?(re, pos = 0)
    re = Regexp.new(re) if re.is_a?(String)
    re.match?(self, pos)
  end

  def =~(re)
    re =~ self
  end

  def sub(pattern, replacement = nil, &block)
    pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
    unless block
      return pattern.__sub_str(self, replacement.to_s)
    end
    md = pattern.match(self)
    return self.dup unless md
    md.pre_match + block.call(md[0]).to_s + md.post_match
  end

  def gsub(pattern, replacement = nil, &block)
    pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
    unless block
      return pattern.__gsub_str(self, replacement.to_s)
    end
    # block case: keep in Ruby to avoid VM callback from C
    parts = []
    rest = self
    while rest.length > 0
      md = pattern.match(rest)
      break unless md
      parts << md.pre_match
      parts << block.call(md[0]).to_s
      matched_len = md[0].length
      if matched_len == 0
        parts << rest[0] if rest.length > 0
        rest = rest[1..-1] || ""
      else
        rest = md.post_match
      end
    end
    parts << rest
    parts.join
  end

  def scan(pattern)
    pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
    result = pattern.__scan(self)
    if block_given?
      result.each { |m| yield m }
      self
    else
      result
    end
  end

  # Regexp-aware split. Falls back to the C-defined split (aliased as
  # `__split` in mrb_mruby_regexp_compat_gem_init before this override
  # loads) for nil or simple-string patterns; converts string-with-
  # backslash to a Regexp and handles regexp patterns in Ruby.
  #
  # Uses `*args` (not `pattern = nil, limit = -1`) because the core
  # `__split` distinguishes "limit omitted" (argc 0/1 → removes
  # trailing empty fields, per MRI default) from "limit explicitly -1"
  # (argc 2 → keeps trailing empty fields). A default of `limit = -1`
  # collapses those two cases and silently breaks the common idiom
  # `"a,b,,,".split(",")` (which should return `["a", "b"]`).
  def split(*args)
    raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 0..2)" if args.length > 2

    pattern = args[0]
    limit_given = args.length >= 2
    limit = limit_given ? args[1] : 0  # 0 = no-limit + remove-trailing (MRI default)

    if pattern.nil? || (pattern.is_a?(String) && (pattern.length == 1 || !pattern.include?('\\')))
      # Forward to core __split preserving the original argc so its
      # "trailing empty" semantics match MRI exactly.
      return limit_given ? __split(pattern, limit) : __split(pattern)
    end

    pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)

    result = []
    rest = self
    count = 0
    while rest.length > 0
      if limit > 0 && count >= limit - 1
        result << rest
        return result
      end
      md = pattern.match(rest)
      break unless md
      result << md.pre_match
      rest = md.post_match
      count += 1
      # skip zero-length match at beginning
      if md[0].length == 0
        if rest.length > 0
          result[-1] = result[-1] + rest[0]
          rest = rest[1..-1] || ""
        else
          break
        end
      end
    end
    result << rest
    # MRI semantics: trailing empties are removed when limit is omitted
    # (limit_given=false, internal default 0) or when limit == 0 was
    # explicitly given. Negative limit keeps them; positive limit was
    # already handled by the early return above.
    if !limit_given || limit == 0
      while result.length > 0 && result[-1] == ""
        result.pop
      end
    end
    result
  end
end
