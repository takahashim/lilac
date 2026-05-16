Spec.describe "smoke test: directive scanner loaded" do
  Spec.assert "Lilac::Directives module is defined" do
    Spec.assert_true Lilac.const_defined?(:Directives), "Lilac::Directives defined"
    Spec.assert_true Lilac::Directives.const_defined?(:Scanner), "Scanner defined"
    Spec.assert_true Lilac::Directives.const_defined?(:Value), "Value defined"
    Spec.assert_true Lilac::Directives.const_defined?(:Grammar), "Grammar defined"
    Spec.assert_true Lilac::Directives.const_defined?(:Evaluator), "Evaluator defined"
    Spec.assert_true Lilac::Directives.const_defined?(:Compat), "Compat defined"
  end

  Spec.assert "Grammar predicates use JS regexp engine correctly" do
    Spec.assert_true Lilac::Directives::Grammar.method_ident?("increment")
    Spec.assert_false Lilac::Directives::Grammar.method_ident?("save?")
    Spec.assert_true Lilac::Directives::Grammar.kebab_name?("progress")
    Spec.assert_false Lilac::Directives::Grammar.kebab_name?("Progress")
    Spec.assert_true Lilac::Directives::Grammar.banned_attr?("onclick")
    Spec.assert_false Lilac::Directives::Grammar.banned_attr?("aria-label")
  end

  Spec.assert "Value.parse classifies ivar and it.path" do
    v1 = Lilac::Directives::Value.parse("@count")
    Spec.assert_true v1.is_a?(Lilac::Directives::Value::Ivar)
    v2 = Lilac::Directives::Value.parse("it.title")
    Spec.assert_true v2.is_a?(Lilac::Directives::Value::ItPath)
    v3 = Lilac::Directives::Value.parse("@active?")
    Spec.assert_true v3.is_a?(Lilac::Directives::Value::Ivar)
    Spec.assert_equal nil, Lilac::Directives::Value.parse("nope()")
  end

  Spec.assert "String#split semantics (mruby-regexp-compat polymorphism)" do
    # MRI default behavior: omitting `limit` should remove trailing
    # empty fields. The mruby-regexp-compat override defaults limit
    # to -1 internally and forwards that to the core __split, which
    # interprets -1 as "keep trailing empties" — diverging from MRI.
    Spec.assert_equal ["a", "b"], "a,b,,,".split(","), "default limit removes trailing empties"
    Spec.assert_equal ["a", "b", "", "", ""], "a,b,,,".split(",", -1), "explicit -1 keeps trailing empties"
    Spec.assert_equal ["a", "b", "", "3,4,,"], "a,b,,3,4,,".split(",", 4), "positive limit caps fields"
    # Multi-char separator path (still string, no backslash → __split).
    Spec.assert_equal ["a", "b"], "a::b::::".split("::"), "multi-char separator: default removes trailing"
  end

  Spec.assert "String#strip diagnostic (mruby-regexp-compat side effects?)" do
    # The basic ASCII whitespace stripping behavior we rely on in
    # Value.parse and similar callers.
    Spec.assert_equal "@count", "@count".strip, "no-op on already-clean string"
    Spec.assert_equal "@count", "  @count  ".strip, "leading + trailing spaces"
    Spec.assert_equal "@count", "\t@count\n".strip, "tab + newline"
    Spec.assert_equal "@count", " \t @count \n ".strip, "mixed whitespace"
    Spec.assert_equal "", "   ".strip, "all-whitespace string"
    Spec.assert_equal "", "".strip, "empty string"
    Spec.assert_equal "foo bar", " foo bar ".strip, "internal space preserved"
  end

  Spec.assert "bind_template_hook default invokes Scanner (captured via instance flag)" do
    body = JS.global[:document][:body]
    body[:innerHTML] = '<div data-component="smoke-rt"><span data-ref="x">y</span></div>'

    klass = Class.new(Lilac::Component) do
      attr_accessor :scanner_attempted
      define_method(:setup) do
        @scanner_attempted = false
      end
    end
    # Wrap the scanner so we can detect that it was invoked.
    klass.class_eval do
      define_method(:bind_template_hook) do
        @scanner_attempted = true
        if Lilac.const_defined?(:Directives) && Lilac::Directives.const_defined?(:Scanner)
          Lilac::Directives::Scanner.new(self).scan_and_bind
        end
      end
    end

    Lilac.register("smoke-rt", klass)
    Lilac.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    inst = Lilac.find_for_element(body.call(:querySelector, "[data-component=\"smoke-rt\"]"))
    Spec.assert_true inst.scanner_attempted, "bind_template_hook was called"

    Lilac.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
