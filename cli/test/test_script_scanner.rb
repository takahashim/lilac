# frozen_string_literal: true

require "test_helper"

class TestScriptScanner < Minitest::Test
  # ---- signal patterns -------------------------------------------

  def test_extracts_signal_declarations
    src = <<~RUBY
      class Counter < Grainet::Component
        def setup
          @count = signal(0)
        end
      end
    RUBY
    assert_includes Grainet::CLI::ScriptScanner.scan(src).signals, "@count"
  end

  def test_extracts_computed_resource_persistent_signal
    src = <<~RUBY
      @doubled = computed { @count.value * 2 }
      @user    = resource(-> { Fetchy.json("/user") })
      @prefs   = persistent_signal(:prefs, default: {})
    RUBY
    signals = Grainet::CLI::ScriptScanner.scan(src).signals
    assert_includes signals, "@doubled"
    assert_includes signals, "@user"
    assert_includes signals, "@prefs"
  end

  def test_ignores_ivar_assignment_to_non_signal_call
    src = <<~RUBY
      @plain = "not a signal"
      @list = [1, 2, 3]
    RUBY
    assert_empty Grainet::CLI::ScriptScanner.scan(src).signals
  end

  def test_ignores_signal_declarations_inside_comments
    src = <<~RUBY
      # @stale = signal(0)
      @real = signal(1)
    RUBY
    signals = Grainet::CLI::ScriptScanner.scan(src).signals
    assert_includes signals, "@real"
    refute_includes signals, "@stale"
  end

  def test_dedupes_repeated_declarations
    src = <<~RUBY
      @count = signal(0)
      @count = signal(1)
    RUBY
    assert_equal ["@count"], Grainet::CLI::ScriptScanner.scan(src).signals
  end

  # ---- method patterns -------------------------------------------

  def test_extracts_def_method
    src = <<~RUBY
      def increment(_ev)
        @count.update(&:succ)
      end

      def reset(_ev) = @count.value = 0
    RUBY
    methods = Grainet::CLI::ScriptScanner.scan(src).methods
    assert_includes methods, "increment"
    assert_includes methods, "reset"
  end

  def test_extracts_predicate_method_name
    src = "def valid?; true; end"
    assert_includes Grainet::CLI::ScriptScanner.scan(src).methods, "valid?"
  end

  def test_extracts_self_method
    src = "def self.factory; new; end"
    assert_includes Grainet::CLI::ScriptScanner.scan(src).methods, "factory"
  end

  # ---- soft ivar-assignment fallback (helper-init coverage) ------

  def test_assigned_ivars_includes_signal_declarations
    # Signal/computed/etc. assignments are also bare `@x =`, so they
    # appear in both sets — the linter prefers strict signals over soft.
    result = Grainet::CLI::ScriptScanner.scan("@count = signal(0)")
    assert_includes result.signals, "@count"
    assert_includes result.assigned_ivars, "@count"
  end

  def test_assigned_ivars_includes_helper_initialized_ivars
    # The classic "helper-method signal init" case the soft fallback
    # exists for.
    src = <<~RUBY
      def setup
        @count = make_counter
      end
      def make_counter
        signal(0)
      end
    RUBY
    result = Grainet::CLI::ScriptScanner.scan(src)
    refute_includes result.signals, "@count"
    assert_includes result.assigned_ivars, "@count"
  end

  def test_assigned_ivars_includes_plain_literal_assignments
    src = <<~RUBY
      @plain = "hello"
      @list  = []
      @num   = 42
    RUBY
    assigned = Grainet::CLI::ScriptScanner.scan(src).assigned_ivars
    assert_includes assigned, "@plain"
    assert_includes assigned, "@list"
    assert_includes assigned, "@num"
  end

  def test_assigned_ivars_excludes_equality_comparison
    src = "if @count == 0; end"
    refute_includes Grainet::CLI::ScriptScanner.scan(src).assigned_ivars, "@count"
  end
end
