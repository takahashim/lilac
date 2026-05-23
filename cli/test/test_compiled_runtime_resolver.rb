# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class TestCompiledRuntimeResolver < Minitest::Test
  Resolver = Lilac::CLI::CompiledRuntimeResolver

  def setup
    @tmp = Dir.mktmpdir("lilac-resolver-test-")
    # Discovery routes inspect ENV; isolate the test from the developer's
    # real env so behaviour is deterministic regardless of who runs it.
    @env_keys = %w[LILAC_COMPILED_WASM MRUBY_WASM_JS_PATH]
    @env_saved = @env_keys.to_h { |k| [k, ENV.delete(k)] }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    @env_saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # ---- wasm discovery -----------------------------------------------

  def test_resolves_wasm_from_explicit_path
    wasm = File.join(@tmp, "explicit.wasm")
    File.binwrite(wasm, "WASM")

    r = Resolver.new(lilac_compiled_path: wasm, project_root: @tmp, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    assert_equal wasm, r.resolve_wasm!
  end

  def test_resolves_wasm_from_env_var
    wasm = File.join(@tmp, "env.wasm")
    File.binwrite(wasm, "WASM")
    ENV["LILAC_COMPILED_WASM"] = wasm

    r = Resolver.new(project_root: @tmp, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    assert_equal wasm, r.resolve_wasm!
  end

  def test_explicit_beats_env_beats_monorepo
    monorepo = File.join(@tmp, "fake-monorepo")
    FileUtils.mkdir_p(File.join(monorepo, "build"))
    File.binwrite(File.join(monorepo, "build", "lilac-compiled.wasm"), "MONOREPO")

    env_wasm = File.join(@tmp, "env.wasm"); File.binwrite(env_wasm, "ENV")
    explicit_wasm = File.join(@tmp, "explicit.wasm"); File.binwrite(explicit_wasm, "EXPLICIT")

    ENV["LILAC_COMPILED_WASM"] = env_wasm

    # Explicit wins
    r1 = Resolver.new(lilac_compiled_path: explicit_wasm, project_root: @tmp, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal explicit_wasm, r1.resolve_wasm!

    # Without explicit, env wins
    r2 = Resolver.new(project_root: @tmp, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal env_wasm, r2.resolve_wasm!

    # Without env, monorepo build/ wins (the last fallback before raise).
    ENV.delete("LILAC_COMPILED_WASM")
    r3 = Resolver.new(project_root: @tmp, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal File.join(monorepo, "build", "lilac-compiled.wasm"), r3.resolve_wasm!
  end

  def test_resolves_wasm_from_monorepo_build_dir
    # `<monorepo_root>/build/lilac-compiled.wasm` is the freshly-built
    # dev artefact, the canonical in-monorepo source after npm/lilac-
    # compiled/ was retired in §25.
    monorepo = File.join(@tmp, "fake-monorepo")
    FileUtils.mkdir_p(File.join(monorepo, "build"))
    File.binwrite(File.join(monorepo, "build", "lilac-compiled.wasm"), "DEV")

    r = Resolver.new(project_root: @tmp, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal File.join(monorepo, "build", "lilac-compiled.wasm"), r.resolve_wasm!
  end

  def test_unresolved_wasm_raises_with_actionable_message
    r = Resolver.new(project_root: @tmp, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    err = assert_raises(Resolver::Error) { r.resolve_wasm! }
    assert_match(/lilac-compiled\.wasm not found/, err.message)
    assert_match(/lilac_compiled_path/, err.message)
    assert_match(/LILAC_COMPILED_WASM/, err.message)
    assert_match(/lilac-wasm-bin/, err.message)
    assert_match(/make lilac-compiled/, err.message)
  end

  # ---- bridge discovery ---------------------------------------------

  def test_resolves_bridge_from_explicit_path
    bridge = File.join(@tmp, "explicit-bridge")
    FileUtils.mkdir_p(bridge)
    File.write(File.join(bridge, "index.js"), "// bridge")

    r = Resolver.new(mruby_wasm_js_path: bridge, project_root: @tmp, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    assert_equal bridge, r.resolve_bridge!
  end

  def test_resolves_bridge_from_monorepo
    monorepo = File.join(@tmp, "fake-monorepo")
    bridge = File.join(monorepo, "mrbgem", "mruby-wasm-js", "js")
    FileUtils.mkdir_p(bridge)
    File.write(File.join(bridge, "index.js"), "// bridge")

    r = Resolver.new(project_root: @tmp, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal bridge, r.resolve_bridge!
  end

  def test_bridge_dir_without_index_js_is_not_a_match
    monorepo = File.join(@tmp, "fake-monorepo")
    bridge = File.join(monorepo, "mrbgem", "mruby-wasm-js", "js")
    FileUtils.mkdir_p(bridge)
    # No index.js file → discovery must skip this candidate.

    r = Resolver.new(project_root: @tmp, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_raises(Resolver::Error) { r.resolve_bridge! }
  end

  def test_unresolved_bridge_raises_with_actionable_message
    r = Resolver.new(project_root: @tmp, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    err = assert_raises(Resolver::Error) { r.resolve_bridge! }
    assert_match(/@takahashim\/mruby-wasm-js bridge not found/, err.message)
    assert_match(/mruby_wasm_js_path/, err.message)
    assert_match(/MRUBY_WASM_JS_PATH/, err.message)
  end
end
