# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestCrossRefLinter < Minitest::Test
  def dir(kind, value:, name: nil, line: 1, tag: "div", ref_id: "lil0")
    Lilac::CLI::Directive.new(
      kind: kind, name: name, value: value, ref_id: ref_id,
      line: line, element_tag: tag, scope_id: nil,
    )
  end

  def lint(script:, directives:, component: "Counter", file: "x.lil", refs_map: {})
    io = StringIO.new
    result = Lilac::CLI::CrossRefLinter.lint(
      script_text: script, directives: directives, refs_map: refs_map,
      component_name: component, file: file, out: io,
    )
    [result.total, io.string]
  end

  # ---- declared signal: no warning ------------------------------

  def test_declared_signal_referenced_in_data_text_emits_no_warning
    count, out = lint(
      script: "@count = signal(0)",
      directives: [dir(:text, value: "@count")],
    )
    assert_equal 0, count
    assert_empty out
  end

  # ---- undeclared signal: warning with context -----------------

  def test_undeclared_signal_emits_warning_with_declared_list
    # Both @count and @total appear in template directives so the
    # dead-signal lint stays quiet; only the @missing typo fires.
    count, out = lint(
      script: "@count = signal(0)\n@total = computed { @count.value }",
      directives: [
        dir(:text, value: "@count"),
        dir(:text, value: "@total"),
        dir(:text, value: "@missing", line: 7),
      ],
    )
    assert_equal 1, count
    assert_includes out, "lilac: lint warning in x.lil:7"
    assert_includes out, "Signal @missing is not declared"
    assert_includes out, "in Counter"
    assert_includes out, "Declared signals: @count, @total."
  end

  # ---- fuzzy suggestion ----------------------------------------

  def test_close_typo_gets_did_you_mean_suggestion
    _, out = lint(
      script: "@unknown_signal = signal(0)",
      directives: [dir(:text, value: "@unkown_signal", line: 3)],
    )
    assert_includes out, "Did you mean: @unknown_signal?"
  end

  def test_far_off_name_does_not_get_suggestion
    _, out = lint(
      script: "@count = signal(0)",
      directives: [dir(:text, value: "@completely_different")],
    )
    refute_includes out, "Did you mean"
  end

  # ---- bare ident is not checked against signals ----------------

  def test_bare_ident_value_inside_iteration_scope_does_not_trigger_signal_warning
    # bare ident is an iteration-item field reference, not a signal
    # reference, so the script-vs-template signal check doesn't fire.
    # Reference @items in the outer data-each so the dead-signal lint
    # doesn't fire on it either.
    each_dir = Lilac::CLI::Directive.new(
      kind: :each, name: nil, value: "@items", ref_id: "lil0",
      line: 1, element_tag: "ul", scope_id: nil,
    )
    key_dir = Lilac::CLI::Directive.new(
      kind: :key, name: nil, value: "id", ref_id: "lil0",
      line: 1, element_tag: "ul", scope_id: nil,
    )
    inside_each = Lilac::CLI::Directive.new(
      kind: :text, name: nil, value: "title", ref_id: "lil1",
      line: 1, element_tag: "span", scope_id: "lil0",
    )
    count, = lint(
      script: "@items = signal([])",
      directives: [each_dir, key_dir, inside_each],
    )
    assert_equal 0, count
  end

  # ---- method linting (data-on-X) ------------------------------

  def test_declared_method_referenced_in_data_on_emits_no_warning
    count, = lint(
      script: "def increment(_ev); end",
      directives: [dir(:on, name: "click", value: "increment", tag: "button")],
    )
    assert_equal 0, count
  end

  def test_undeclared_method_emits_warning_with_suggestion
    _, out = lint(
      script: "def increment(_ev); end",
      directives: [dir(:on, name: "click", value: "incremnt", line: 4, tag: "button")],
    )
    assert_includes out, "Method `incremnt`"
    assert_includes out, "not defined in Counter"
    assert_includes out, "Did you mean: increment?"
  end

  # ---- data-class hash values are walked -----------------------

  def test_data_class_with_undeclared_ivar_emits_warning
    _, out = lint(
      script: "@active = signal(false)",
      directives: [dir(:class_, value: "{ active: @active, big: @bigg }", line: 9)],
    )
    assert_includes out, "Signal @bigg"
    refute_includes out, "Signal @active"
  end

  # ---- soft fallback: helper-method ivar init suppresses warning -

  def test_helper_method_initialized_ivar_does_not_warn
    # `@count = make_counter` doesn't match SIGNAL_DECL (RHS isn't a
    # signal call), but the soft IVAR_ASSIGN scan picks up the bare
    # `@count =` so the linter trusts the user.
    count, out = lint(
      script: <<~RUBY,
        def setup
          @count = make_counter
        end
        def make_counter; signal(0); end
      RUBY
      directives: [dir(:text, value: "@count")],
    )
    assert_equal 0, count
    assert_empty out
  end

  def test_plain_literal_ivar_does_not_warn_at_build_time
    # `@plain = "hello"` is not a signal, but the soft fallback marks
    # it as assigned so the linter stays quiet — the cost is paid at
    # runtime via NoMethodError on `.value`, which the user sees in
    # the browser console.
    count, = lint(
      script: %(@plain = "hello"),
      directives: [dir(:text, value: "@plain")],
    )
    assert_equal 0, count
  end

  def test_genuine_typo_still_caught_even_with_soft_fallback
    # The user has @count (strict + soft) and @plain (soft only).
    # Template typo `@coutn` matches neither set → warning fires.
    _, out = lint(
      script: <<~RUBY,
        @count = signal(0)
        @plain = "hello"
      RUBY
      directives: [dir(:text, value: "@coutn", line: 5)],
    )
    assert_includes out, "Signal @coutn"
    assert_includes out, "Did you mean: @count?"
  end

  # ---- data-each without data-key (lint) ------------------------

  def test_data_each_without_key_emits_warning
    _, out = lint(
      script: "@items = signal([])",
      directives: [dir(:each, value: "@items", line: 6, tag: "ul")],
    )
    assert_includes out, "x.lil:6"
    assert_includes out, "data-each without data-key"
    assert_includes out, "object_id"
  end

  def test_data_each_with_matching_key_emits_no_warning
    each_dir = dir(:each, value: "@items", line: 6, tag: "ul", ref_id: "gE")
    key_dir = Lilac::CLI::Directive.new(
      kind: :key, name: nil, value: "id", ref_id: "gE",
      line: 6, element_tag: "ul", scope_id: nil,
    )
    count, = lint(script: "@items = signal([])", directives: [each_dir, key_dir])
    assert_equal 0, count
  end

  # ---- reserved data-ref name (lint) ----------------------------

  def test_data_ref_collides_with_kernel_method_emits_warning
    _, out = lint(
      script: "",
      directives: [],
      refs_map: { "p" => 4, "class" => 5 },
    )
    assert_includes out, "data-ref \"p\" collides"
    assert_includes out, "data-ref \"class\" collides"
    assert_includes out, "x.lil:4"
    assert_includes out, "x.lil:5"
  end

  def test_non_kernel_ref_name_does_not_trigger
    count, = lint(
      script: "",
      directives: [],
      refs_map: { "message" => 2, "submit_btn" => 3 },
    )
    assert_equal 0, count
  end

  # ---- dead-code (lint, AST-based) ------------------------------

  def test_declared_signal_used_only_in_computed_block_is_not_dead
    # The AST walker sees `@count.value` inside the computed block,
    # so @count is properly recognised as live even though no
    # directive references it directly.
    count, = lint(
      script: <<~RUBY,
        @count = signal(0)
        @doubled = computed { @count.value * 2 }
      RUBY
      directives: [dir(:text, value: "@doubled")],
    )
    assert_equal 0, count
  end

  def test_truly_unreferenced_signal_emits_dead_warning
    _, out = lint(
      script: <<~RUBY,
        @used = signal(0)
        @orphan = signal(1)
      RUBY
      directives: [dir(:text, value: "@used")],
    )
    assert_includes out, "Signal @orphan is declared"
    assert_includes out, "never read"
    refute_includes out, "@used is declared"
  end

  def test_helper_method_called_from_setup_is_not_dead
    # The AST walker sees the `make_counter` call inside `setup`, so
    # the dead-method lint correctly leaves it alone.
    count, = lint(
      script: <<~RUBY,
        def setup
          @count = make_counter
        end
        def make_counter; signal(0); end
      RUBY
      directives: [dir(:text, value: "@count")],
    )
    assert_equal 0, count
  end

  def test_truly_unreferenced_method_emits_dead_warning
    _, out = lint(
      script: <<~RUBY,
        def used(_ev); end
        def ghost(_ev); end
      RUBY
      directives: [dir(:on, name: "click", value: "used", tag: "button")],
    )
    assert_includes out, "Method `ghost` is defined"
    refute_includes out, "Method `used`"
  end

  def test_lifecycle_methods_never_dead
    count, = lint(
      script: <<~RUBY,
        def setup; end
        def bind_template_hook; end
      RUBY
      directives: [],
    )
    assert_equal 0, count
  end

  def test_send_symbol_call_keeps_method_alive
    # Dynamic dispatch via `send(:foo)` is statically recoverable
    # when the argument is a symbol literal — the dead-method lint
    # should treat the target as called.
    count, = lint(
      script: <<~RUBY,
        def setup
          send(:foo)
        end
        def foo; end
      RUBY
      directives: [],
    )
    assert_equal 0, count
  end
end
