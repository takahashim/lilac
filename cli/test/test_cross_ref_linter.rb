# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestCrossRefLinter < Minitest::Test
  def dir(kind, value:, name: nil, line: 1, tag: "div", ref_id: "g0")
    Grainet::CLI::Directive.new(
      kind: kind, name: name, value: value, ref_id: ref_id,
      line: line, element_tag: tag, scope_id: nil,
    )
  end

  def lint(script:, directives:, component: "Counter", file: "x.gnt", refs_map: {})
    io = StringIO.new
    count = Grainet::CLI::CrossRefLinter.lint(
      script_text: script, directives: directives, refs_map: refs_map,
      component_name: component, file: file, out: io,
    )
    [count, io.string]
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
    count, out = lint(
      script: "@count = signal(0)\n@total = computed { @count.value }",
      directives: [dir(:text, value: "@missing", line: 7)],
    )
    assert_equal 1, count
    assert_includes out, "grainet: lint warning in x.gnt:7"
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

  # ---- it_path is not checked against signals ------------------

  def test_it_path_value_inside_iteration_scope_does_not_trigger_signal_warning
    # it_path is not a signal reference, so the script-vs-template
    # signal check doesn't fire. (At top level it would trigger the
    # separate "it outside data-each" warning — see below.)
    inside_each = Grainet::CLI::Directive.new(
      kind: :text, name: nil, value: "it.title", ref_id: "g1",
      line: 1, element_tag: "span", scope_id: "g0",
    )
    count, = lint(script: "@items = signal([])", directives: [inside_each])
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

  # ---- it outside data-each (lint) ------------------------------

  def test_it_path_at_top_level_emits_warning
    # `it` only binds inside a data-each iteration body; using it at
    # top level (scope_id nil) means the generated code would crash.
    _, out = lint(
      script: "",
      directives: [dir(:text, value: "it.title", line: 3)],
    )
    assert_includes out, "x.gnt:3"
    assert_includes out, "`it` referenced outside a data-each"
  end

  def test_it_path_inside_data_each_scope_is_fine
    each_scope_dir = Grainet::CLI::Directive.new(
      kind: :text, name: nil, value: "it.title", ref_id: "g1",
      line: 4, element_tag: "span", scope_id: "g0",
    )
    count, = lint(script: "", directives: [each_scope_dir])
    assert_equal 0, count
  end

  # ---- data-each without data-key (lint) ------------------------

  def test_data_each_without_key_emits_warning
    _, out = lint(
      script: "@items = signal([])",
      directives: [dir(:each, value: "@items", line: 6, tag: "ul")],
    )
    assert_includes out, "x.gnt:6"
    assert_includes out, "data-each without data-key"
    assert_includes out, "object_id"
  end

  def test_data_each_with_matching_key_emits_no_warning
    each_dir = dir(:each, value: "@items", line: 6, tag: "ul", ref_id: "gE")
    key_dir = Grainet::CLI::Directive.new(
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
      refs_map: { "p" => { tag: "p", line: 4 }, "class" => { tag: "span", line: 5 } },
    )
    assert_includes out, "data-ref \"p\" collides"
    assert_includes out, "data-ref \"class\" collides"
    assert_includes out, "x.gnt:4"
    assert_includes out, "x.gnt:5"
  end

  def test_non_kernel_ref_name_does_not_trigger
    count, = lint(
      script: "",
      directives: [],
      refs_map: { "message" => { tag: "p", line: 2 }, "submit_btn" => { tag: "button", line: 3 } },
    )
    assert_equal 0, count
  end
end
