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
    count = Lilac::CLI::CrossRefLinter.lint(
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

  # ---- it_path is not checked against signals ------------------

  def test_it_path_value_inside_iteration_scope_does_not_trigger_signal_warning
    # it_path is not a signal reference, so the script-vs-template
    # signal check doesn't fire. (At top level it would trigger the
    # separate "it outside data-each" warning — see below.)
    # Reference @items in the outer data-each so the dead-signal
    # lint doesn't fire on it either.
    each_dir = Lilac::CLI::Directive.new(
      kind: :each, name: nil, value: "@items", ref_id: "lil0",
      line: 1, element_tag: "ul", scope_id: nil,
    )
    key_dir = Lilac::CLI::Directive.new(
      kind: :key, name: nil, value: "id", ref_id: "lil0",
      line: 1, element_tag: "ul", scope_id: nil,
    )
    inside_each = Lilac::CLI::Directive.new(
      kind: :text, name: nil, value: "it.title", ref_id: "lil1",
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

  # ---- it outside data-each (lint) ------------------------------

  def test_it_path_at_top_level_emits_warning
    # `it` only binds inside a data-each iteration body; using it at
    # top level (scope_id nil) means the generated code would crash.
    _, out = lint(
      script: "",
      directives: [dir(:text, value: "it.title", line: 3)],
    )
    assert_includes out, "x.lil:3"
    assert_includes out, "`it` referenced outside a data-each"
  end

  def test_it_path_inside_data_each_scope_is_fine
    each_scope_dir = Lilac::CLI::Directive.new(
      kind: :text, name: nil, value: "it.title", ref_id: "lil1",
      line: 4, element_tag: "span", scope_id: "lil0",
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
      refs_map: { "p" => { tag: "p", line: 4 }, "class" => { tag: "span", line: 5 } },
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
      refs_map: { "message" => { tag: "p", line: 2 }, "submit_btn" => { tag: "button", line: 3 } },
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

  # ---- form / field / button cross-reference ---------------------

  def form_dir(kind, value:, form_scope: nil, line: 1, tag: "div")
    Lilac::CLI::Directive.new(
      kind: kind, name: nil, value: value, ref_id: "lil0",
      line: line, element_tag: tag, scope_id: nil,
      form_scope: form_scope,
    )
  end

  def test_declared_button_in_default_form_emits_no_warning
    count, = lint(
      script: <<~RUBY,
        form do |f|
          f.button :save do |_v|
          end
        end
      RUBY
      directives: [form_dir(:button, value: "save", form_scope: :default, tag: "button")],
    )
    assert_equal 0, count
  end

  def test_undeclared_button_emits_error_with_suggestion
    result, out = lint(
      script: <<~RUBY,
        form do |f|
          f.button :save do |_v|
          end
        end
      RUBY
      directives: [form_dir(:button, value: "sav", form_scope: :default, line: 7, tag: "button")],
    )
    assert_equal 1, result.errors
    assert_includes out, "lint error"
    assert_includes out, "data-button=\"sav\""
    assert_includes out, "form(:default)"
    assert_includes out, "Did you mean: save?"
  end

  def test_undeclared_field_emits_warning_with_suggestion
    result, out = lint(
      script: <<~RUBY,
        form do |f|
          f.field :email, initial: ""
        end
      RUBY
      directives: [form_dir(:field, value: "emial", form_scope: :default, line: 5, tag: "input")],
    )
    assert_equal 0, result.errors
    assert_equal 1, result.warnings
    assert_includes out, "lint warning"
    assert_includes out, "data-field=\"emial\""
    assert_includes out, "Did you mean: email?"
  end

  def test_declared_field_in_named_form_emits_no_warning
    count, = lint(
      script: <<~RUBY,
        form :signup do |f|
          f.field :email, initial: ""
        end
      RUBY
      directives: [form_dir(:field, value: "email", form_scope: :signup, tag: "input")],
    )
    assert_equal 0, count
  end

  def test_field_in_undeclared_form_warns
    result, out = lint(
      script: "",
      directives: [form_dir(:field, value: "email", form_scope: :signup, line: 3, tag: "input")],
    )
    assert_equal 1, result.warnings
    assert_includes out, "data-field=\"email\" in form(:signup)"
  end

  def test_undeclared_named_form_emits_warning
    # Use a near-typo so the suggestion fires (`signup` → `signupp`).
    result, out = lint(
      script: <<~RUBY,
        form :signup do |f|
        end
      RUBY
      directives: [form_dir(:form, value: "signupp", line: 4, tag: "form")],
    )
    assert_equal 1, result.warnings
    assert_includes out, "data-form=\"signupp\""
    assert_includes out, "Did you mean: signup?"
  end

  def test_data_form_default_never_warns
    # `<form data-form="default">` (or no data-form at all) is fine
    # without an explicit `form do |f| ... end` declaration — the
    # framework auto-creates the default form on first access.
    count, = lint(
      script: "",
      directives: [form_dir(:form, value: "default", tag: "form")],
    )
    assert_equal 0, count
  end

  def test_button_block_param_other_than_f_works
    # The visitor anchors `<block_param>.button` calls to whatever
    # name appears in the block signature — `do |form_builder| ... end`
    # should be recognised just like the conventional `|f|`.
    count, = lint(
      script: <<~RUBY,
        form do |form_builder|
          form_builder.button :save do |_v|
          end
        end
      RUBY
      directives: [form_dir(:button, value: "save", form_scope: :default, tag: "button")],
    )
    assert_equal 0, count
  end
end
