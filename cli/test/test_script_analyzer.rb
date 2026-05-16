# frozen_string_literal: true

require "test_helper"

class TestScriptAnalyzer < Minitest::Test
  def analyze(src)
    Lilac::CLI::ScriptAnalyzer.analyze(src)
  end

  # ---- signal declarations ---------------------------------------

  def test_extracts_signal_with_line
    src = <<~RUBY
      class Counter
        def setup
          @count = signal(0)
        end
      end
    RUBY
    result = analyze(src)
    assert result.declares_signal?("@count")
    assert_equal 3, result.declared_signals["@count"]
  end

  def test_extracts_computed_resource_persistent_signal
    src = <<~RUBY
      @doubled = computed { @count.value * 2 }
      @user    = resource(-> { Fetchy.json("/u") })
      @prefs   = persistent_signal(:prefs, default: {})
    RUBY
    sigs = analyze(src).declared_signals
    assert sigs.key?("@doubled")
    assert sigs.key?("@user")
    assert sigs.key?("@prefs")
  end

  def test_plain_assignment_is_not_a_signal_declaration
    src = '@plain = "hello"'
    refute analyze(src).declares_signal?("@plain")
  end

  def test_or_equals_to_signal_factory_counts_as_declaration
    src = "@cache ||= signal({})"
    assert analyze(src).declares_signal?("@cache")
  end

  # ---- method declarations --------------------------------------

  def test_extracts_def_method_with_line
    src = <<~RUBY
      def increment(_ev)
      end

      def reset(_ev) = @count.value = 0
    RUBY
    methods = analyze(src).declared_methods
    assert_equal 1, methods["increment"]
    assert_equal 4, methods["reset"]
  end

  def test_extracts_predicate_method_name
    assert analyze("def valid?; true; end").declares_method?("valid?")
  end

  # ---- ivar reads (used by dead-signal lint) --------------------

  def test_records_ivar_reads_outside_declaration
    src = <<~RUBY
      @count = signal(0)
      @doubled = computed { @count.value * 2 }
    RUBY
    refs = analyze(src).referenced_ivars
    # @count is read inside the computed block (the dead-code linter
    # uses this to keep @count from being flagged as unused).
    assert_includes refs, "@count"
  end

  def test_assignment_does_not_count_as_read
    # `@x = signal(0)` alone leaves @x unreferenced — needed so the
    # dead-signal lint catches truly unused signals.
    src = "@orphan = signal(0)"
    refute_includes analyze(src).referenced_ivars, "@orphan"
  end

  # ---- method calls (used by dead-method lint) ------------------

  def test_records_method_calls
    src = <<~RUBY
      def setup
        init_state
        increment(nil)
      end
    RUBY
    calls = analyze(src).method_calls
    assert_includes calls, "init_state"
    assert_includes calls, "increment"
  end

  def test_records_send_with_symbol_literal_as_call
    src = "send(:foo)"
    assert_includes analyze(src).method_calls, "foo"
  end

  def test_records_public_send_with_symbol_literal_as_call
    src = "public_send(:bar, 1, 2)"
    assert_includes analyze(src).method_calls, "bar"
  end

  def test_records_method_object_with_symbol_literal_as_call
    src = "m = method(:baz)"
    assert_includes analyze(src).method_calls, "baz"
  end

  # ---- syntactically invalid scripts ----------------------------

  def test_unparseable_script_returns_empty_result
    src = "def foo("  # malformed
    result = analyze(src)
    assert_empty result.declared_methods
    assert_empty result.declared_signals
  end
end
