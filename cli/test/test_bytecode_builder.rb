# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class TestBytecodeBuilder < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('lilac-bytecode-test')
    @output = File.join(@tmp, 'dist')
    FileUtils.mkdir_p(@output)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def builder(**opts)
    # Existing tests assume no gem-provided wasm fallback (priority #4
    # in `resolve_backend`). The monorepo carries `build/mrbc-host.wasm`,
    # which `Lilac::Wasm::Bin.mrbc_host_wasm` happily resolves — these
    # tests want to assert the binary-only resolution chain, so they
    # opt out of gem discovery by default. The wasm-backend cases below
    # explicitly enable it.
    Lilac::CLI::BytecodeBuilder.new(
      output_dir: @output,
      disable_gem_discovery: true,
      **opts
    )
  end

  # ---- mrbc path resolution -----------------------------------------

  def test_resolve_mrbc_prefers_explicit_argument
    fake = File.join(@tmp, 'fake-mrbc')
    File.write(fake, '')
    FileUtils.chmod('a+x', fake)
    b = builder(mrbc_path: fake)
    assert_equal fake, b.resolve_mrbc
  end

  def test_resolve_mrbc_falls_back_to_env_mrbc
    fake = File.join(@tmp, 'env-mrbc')
    File.write(fake, '')
    FileUtils.chmod('a+x', fake)
    with_env('MRBC' => fake, 'MRUBY_WASM_RUNTIME_PATH' => nil) do
      assert_equal fake, builder.resolve_mrbc
    end
  end

  def test_resolve_mrbc_uses_runtime_path_when_set
    # Layout that mirrors mruby-wasm-runtime's expected mrbc location.
    base = File.join(@tmp, 'wasm-runtime')
    target = File.join(base, 'mruby', 'build', 'host', 'bin', 'mrbc')
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, '')
    FileUtils.chmod('a+x', target)
    with_env('MRBC' => nil, 'MRUBY_WASM_RUNTIME_PATH' => base) do
      assert_equal target, builder.resolve_mrbc
    end
  end

  def test_resolve_mrbc_returns_nil_when_nothing_found
    with_env('MRBC' => nil, 'MRUBY_WASM_RUNTIME_PATH' => nil, 'PATH' => '/nonexistent') do
      assert_nil builder.resolve_mrbc
    end
  end

  # ---- build pipeline ---------------------------------------------

  def test_build_invokes_mrbc_and_writes_hashed_mrb
    mrbc = real_mrbc_or_skip
    b = builder(mrbc_path: mrbc)
    filename = b.build("puts 'hello'", source_label: 'test')
    assert_match(/\Aapp\.[0-9a-f]{8}\.mrb\z/, filename,
                 "expected hashed filename, got #{filename.inspect}")
    bytes = File.binread(File.join(@output, filename))
    assert_operator bytes.bytesize, :>, 0, 'produced .mrb should not be empty'
    # mruby bytecode files start with "RITE" magic. The byte 'R' is 0x52.
    assert_equal 'RITE', bytes[0, 4], 'produced .mrb should have RITE magic header'
  end

  def test_build_filename_changes_when_content_changes
    mrbc = real_mrbc_or_skip
    b = builder(mrbc_path: mrbc)
    f1 = b.build('a = 1')
    f2 = b.build('a = 2')
    refute_equal f1, f2,
                 'different sources should produce different hash filenames'
  end

  def test_build_filename_stable_for_same_content
    mrbc = real_mrbc_or_skip
    b = builder(mrbc_path: mrbc)
    f1 = b.build('a = 1')
    f2 = b.build('a = 1')
    assert_equal f1, f2,
                 'identical sources should produce the same hash filename'
  end

  def test_build_raises_when_no_backend_resolves
    with_env('MRBC' => nil, 'MRUBY_WASM_RUNTIME_PATH' => nil, 'PATH' => '/nonexistent') do
      err = assert_raises(Lilac::CLI::BytecodeBuilder::Error) do
        builder.build("puts 'x'")
      end
      assert_includes err.message, 'No mrbc backend found'
    end
  end

  def test_build_raises_with_mrbc_stderr_on_compile_error
    mrbc = real_mrbc_or_skip
    b = builder(mrbc_path: mrbc)
    err = assert_raises(Lilac::CLI::BytecodeBuilder::Error) do
      b.build('def 1bad; end') # invalid Ruby — mrbc reports a syntax error
    end
    assert_includes err.message, 'mrbc failed'
  end

  # ---- wasm backend ------------------------------------------------

  def test_resolve_backend_prefers_binary_over_wasm
    fake = File.join(@tmp, 'fake-mrbc')
    File.write(fake, '')
    FileUtils.chmod('a+x', fake)
    # disable_gem_discovery default is true in the helper, but we still
    # want to assert the *priority*: even if the gem wasm IS available,
    # an explicit binary wins. Re-enable discovery here.
    b = Lilac::CLI::BytecodeBuilder.new(
      output_dir: @output,
      mrbc_path: fake,
      disable_gem_discovery: false
    )
    backend = b.resolve_backend
    assert_equal :binary, backend.first
    assert_equal fake, backend.last
  end

  def test_resolve_backend_picks_wasm_when_no_binary_and_gem_wasm_loadable
    wasm = real_mrbc_host_wasm_or_skip
    with_env('MRBC' => nil, 'MRUBY_WASM_RUNTIME_PATH' => nil, 'PATH' => '/nonexistent') do
      b = Lilac::CLI::BytecodeBuilder.new(
        output_dir: @output,
        disable_gem_discovery: false
      )
      backend = b.resolve_backend
      assert_equal :wasm, backend.first
      assert_equal wasm, backend.last
    end
  end

  def test_build_via_wasm_backend_produces_rite_magic
    real_mrbc_host_wasm_or_skip
    with_env('MRBC' => nil, 'MRUBY_WASM_RUNTIME_PATH' => nil, 'PATH' => '/nonexistent') do
      b = Lilac::CLI::BytecodeBuilder.new(
        output_dir: @output,
        disable_gem_discovery: false
      )
      filename = b.build("puts 'hello'", source_label: 'wasm-test')
      assert_match(/\Aapp\.[0-9a-f]{8}\.mrb\z/, filename)
      bytes = File.binread(File.join(@output, filename))
      assert_equal 'RITE', bytes[0, 4]
    end
  end

  def test_build_via_wasm_backend_surfaces_compile_errors
    real_mrbc_host_wasm_or_skip
    with_env('MRBC' => nil, 'MRUBY_WASM_RUNTIME_PATH' => nil, 'PATH' => '/nonexistent') do
      b = Lilac::CLI::BytecodeBuilder.new(
        output_dir: @output,
        disable_gem_discovery: false
      )
      err = assert_raises(Lilac::CLI::BytecodeBuilder::Error) do
        b.build('def 1bad; end')
      end
      assert_includes err.message, 'mrbc-host.wasm failed'
    end
  end

  private

  # Locate the gem-bundled mrbc-host.wasm and verify the wasm backend
  # can be instantiated, or skip cleanly. Used by the wasm-backend tests
  # so a checkout without the wasm built locally (e.g. fresh clone, no
  # `make mrbc-host`) doesn't fail the whole suite.
  def real_mrbc_host_wasm_or_skip
    require 'lilac/wasm/bin'
    wasm = Lilac::Wasm::Bin.mrbc_host_wasm
    skip 'mrbc-host.wasm not built (run `make mrbc-host`)' unless wasm && File.file?(wasm)
    unless Lilac::CLI::WasmMrbcDriver.available?(wasm_path: wasm)
      skip "wasmtime can't load mrbc-host.wasm (released gem missing wasm_exceptions config?)"
    end
    wasm
  end

  # Locate an actual mrbc binary or skip the test gracefully so CI
  # without mruby installed doesn't fail the whole suite.
  def real_mrbc_or_skip
    return ENV['MRBC'] if ENV['MRBC'] && File.executable?(ENV['MRBC'])

    if (mwr = ENV['MRUBY_WASM_RUNTIME_PATH'])
      candidate = File.join(mwr, 'mruby', 'build', 'host', 'bin', 'mrbc')
      return candidate if File.executable?(candidate)
    end
    on_path = (ENV['PATH'] || '').split(File::PATH_SEPARATOR).map { |d| File.join(d, 'mrbc') }.find do |p|
      File.executable?(p) && !File.directory?(p)
    end
    return on_path if on_path

    skip 'mrbc not available; set MRBC or MRUBY_WASM_RUNTIME_PATH to run this test'
  end

  # Temporarily override ENV vars (nil = unset). Restores on exit.
  def with_env(env)
    saved = env.keys.to_h { |k| [k, ENV[k]] }
    env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
