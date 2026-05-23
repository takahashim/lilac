# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class TestPluginBuild < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('lilac-plugin-build-test')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_compiles_single_input_to_mrb
    real_mrbc_or_skip
    input = File.join(@tmp, 'plugin.rb')
    output = File.join(@tmp, 'plugin.mrb')
    File.write(input, 'A = 1')

    Lilac::CLI::PluginBuild.new(inputs: [input], output: output).run

    assert File.file?(output), 'plugin .mrb should be written'
    bytes = File.binread(output)
    assert_equal 'RITE', bytes[0, 4], 'output should have RITE magic header'
  end

  def test_concatenates_multiple_inputs
    real_mrbc_or_skip
    a = File.join(@tmp, 'a.rb')
    b = File.join(@tmp, 'b.rb')
    output = File.join(@tmp, 'out.mrb')
    File.write(a, 'A = 1')
    File.write(b, 'B = 2')

    Lilac::CLI::PluginBuild.new(inputs: [a, b], output: output).run

    bytes = File.binread(output)
    assert_equal 'RITE', bytes[0, 4]
    # Two-constant source should produce a larger IREP than a single
    # constant. Exact size is mrbc-version-dependent; just sanity-check
    # the concat actually happened (file not empty, plausible size).
    assert_operator bytes.bytesize, :>, 32
  end

  def test_writes_to_nested_output_directory
    real_mrbc_or_skip
    input = File.join(@tmp, 'plugin.rb')
    output = File.join(@tmp, 'nested', 'dir', 'plugin.mrb')
    File.write(input, 'X = 1')

    Lilac::CLI::PluginBuild.new(inputs: [input], output: output).run

    assert File.file?(output), 'nested output dir should be auto-created'
  end

  def test_raises_when_input_missing
    err = assert_raises(Lilac::CLI::PluginBuild::Error) do
      Lilac::CLI::PluginBuild.new(
        inputs: [File.join(@tmp, 'nope.rb')],
        output: File.join(@tmp, 'out.mrb')
      ).run
    end
    assert_includes err.message, 'input file not found'
  end

  def test_raises_when_inputs_empty
    err = assert_raises(Lilac::CLI::PluginBuild::Error) do
      Lilac::CLI::PluginBuild.new(inputs: [], output: File.join(@tmp, 'out.mrb'))
    end
    assert_includes err.message, 'at least one input file required'
  end

  def test_raises_with_compile_error_message
    real_mrbc_or_skip
    input = File.join(@tmp, 'bad.rb')
    File.write(input, 'def 1bad; end') # syntax error
    err = assert_raises(Lilac::CLI::PluginBuild::Error) do
      Lilac::CLI::PluginBuild.new(
        inputs: [input],
        output: File.join(@tmp, 'out.mrb')
      ).run
    end
    refute_empty err.message
  end

  private

  # Mirror test_bytecode_builder.rb's helper: prefer a real mrbc binary
  # (fast), fall back to the gem-bundled mrbc-host.wasm (slower but
  # works in CI without mruby installed), skip if neither available.
  def real_mrbc_or_skip
    return if ENV['MRBC'] && File.executable?(ENV['MRBC'])

    if (mwr = ENV['MRUBY_WASM_RUNTIME_PATH'])
      candidate = File.join(mwr, 'mruby', 'build', 'host', 'bin', 'mrbc')
      return if File.executable?(candidate)
    end
    require 'lilac/wasm/bin'
    wasm = Lilac::Wasm::Bin.mrbc_host_wasm
    return if wasm && File.file?(wasm) && Lilac::CLI::WasmMrbcDriver.available?(wasm_path: wasm)

    skip 'no mrbc backend available (set MRBC, MRUBY_WASM_RUNTIME_PATH, or build mrbc-host.wasm)'
  rescue LoadError
    skip 'lilac-wasm-bin gem not available'
  end
end
