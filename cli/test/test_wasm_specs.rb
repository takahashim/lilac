# frozen_string_literal: true

require_relative "test_helper"

# Minitest wrapper around `test/ruby_spec/spec_runner.rb`. One test
# method per pure-mruby spec file so failures point at the offending
# fixture, and so this integrates with `bundle exec rake test`.
#
# Skips cleanly when `build/lilac-full-host.wasm` is absent (CI without
# `make lilac-full-host`) or when `MRUBY_WASM_RUNTIME_PATH` is unset.
class TestWasmSpecs < Minitest::Test
  RUBY_SPEC_DIR = File.expand_path("../../test/ruby_spec", __dir__)
  require File.join(RUBY_SPEC_DIR, "spec_runner")

  SpecRunner::PURE_SPECS.each do |spec_rel|
    define_method("test_#{spec_rel.tr('/', '_').sub('.rb', '')}") do
      unless ENV["MRUBY_WASM_RUNTIME_PATH"]
        skip "MRUBY_WASM_RUNTIME_PATH unset — needed to find spec_helper.rb"
      end
      unless File.file?(MrubyWasm::DEFAULT_WASM_PATH)
        skip "build/lilac-full-host.wasm not built (run `make lilac-full-host`)"
      end

      result = SpecRunner.new(specs: [spec_rel]).run.first
      assert result.rc.zero?, "spec parse/runtime failed (rc=#{result.rc})\n#{result.stderr}"
      assert_equal 0, result.fail,
                   "#{result.fail} assertion(s) failed in #{spec_rel}:\n" \
                   "#{result.stdout.lines.grep(/^\[FAIL\]| - /).join}"
    end
  end
end
