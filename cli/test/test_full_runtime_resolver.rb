# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class TestFullRuntimeResolver < Minitest::Test
  Resolver = Lilac::CLI::FullRuntimeResolver

  def setup
    @tmp = Dir.mktmpdir("lilac-full-resolver-test-")
    # Discovery routes inspect ENV; isolate the test from the developer's
    # real env so behaviour is deterministic regardless of who runs it.
    @env_keys = %w[LILAC_FULL_WASM MRUBY_WASM_JS_PATH]
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

    r = Resolver.new(lilac_full_path: wasm, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    assert_equal wasm, r.resolve_wasm!
  end

  def test_resolves_wasm_from_env_var
    wasm = File.join(@tmp, "env.wasm")
    File.binwrite(wasm, "WASM")
    ENV["LILAC_FULL_WASM"] = wasm

    r = Resolver.new(monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    assert_equal wasm, r.resolve_wasm!
  end

  def test_explicit_beats_env_beats_monorepo
    monorepo = File.join(@tmp, "fake-monorepo")
    FileUtils.mkdir_p(File.join(monorepo, "build"))
    File.binwrite(File.join(monorepo, "build", "lilac-full.wasm"), "MONOREPO")

    env_wasm = File.join(@tmp, "env.wasm"); File.binwrite(env_wasm, "ENV")
    explicit_wasm = File.join(@tmp, "explicit.wasm"); File.binwrite(explicit_wasm, "EXPLICIT")

    ENV["LILAC_FULL_WASM"] = env_wasm

    # Explicit wins
    r1 = Resolver.new(lilac_full_path: explicit_wasm, monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal explicit_wasm, r1.resolve_wasm!

    # Without explicit, env wins
    r2 = Resolver.new(monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal env_wasm, r2.resolve_wasm!

    # Without env, monorepo build/ wins (the last fallback before raise).
    ENV.delete("LILAC_FULL_WASM")
    r3 = Resolver.new(monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal File.join(monorepo, "build", "lilac-full.wasm"), r3.resolve_wasm!
  end

  def test_resolves_wasm_from_monorepo_build_dir
    monorepo = File.join(@tmp, "fake-monorepo")
    FileUtils.mkdir_p(File.join(monorepo, "build"))
    File.binwrite(File.join(monorepo, "build", "lilac-full.wasm"), "DEV")

    r = Resolver.new(monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal File.join(monorepo, "build", "lilac-full.wasm"), r.resolve_wasm!
  end

  def test_unresolved_wasm_raises_with_actionable_message
    r = Resolver.new(monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    err = assert_raises(Resolver::Error) { r.resolve_wasm! }
    assert_match(/lilac-full\.wasm not found/, err.message)
    assert_match(/lilac_full_path/, err.message)
    assert_match(/LILAC_FULL_WASM/, err.message)
    assert_match(/lilac-wasm-bin/, err.message)
    assert_match(/make lilac-full/, err.message)
  end

  def test_error_is_distinct_from_compiled_but_shares_ancestor
    r = Resolver.new(monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)

    err = assert_raises(Lilac::CLI::FullRuntimeResolver::Error) { r.resolve_wasm! }
    # Common ancestor: rescuable as RuntimeResolver::Error.
    assert_kind_of Lilac::CLI::RuntimeResolver::Error, err
    # Distinct: a CompiledRuntimeResolver::Error rescue must NOT catch it.
    refute_kind_of Lilac::CLI::CompiledRuntimeResolver::Error, err
  end

  # ---- bridge discovery (shared artifact; same logic as :compiled) ---

  def test_resolves_bridge_from_explicit_path
    bridge = File.join(@tmp, "explicit-bridge")
    FileUtils.mkdir_p(bridge)
    File.write(File.join(bridge, "index.js"), "// bridge")

    r = Resolver.new(mruby_wasm_js_path: bridge, monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    assert_equal bridge, r.resolve_bridge!
  end

  def test_resolves_bridge_from_monorepo
    monorepo = File.join(@tmp, "fake-monorepo")
    bridge = File.join(monorepo, "mrbgem", "mruby-wasm-js", "js")
    FileUtils.mkdir_p(bridge)
    File.write(File.join(bridge, "index.js"), "// bridge")

    r = Resolver.new(monorepo_root: monorepo, disable_gem_discovery: true)
    assert_equal bridge, r.resolve_bridge!
  end

  def test_bridge_dir_without_index_js_is_not_a_match
    monorepo = File.join(@tmp, "fake-monorepo")
    bridge = File.join(monorepo, "mrbgem", "mruby-wasm-js", "js")
    FileUtils.mkdir_p(bridge)
    # No index.js file → discovery must skip this candidate.

    r = Resolver.new(monorepo_root: monorepo, disable_gem_discovery: true)
    assert_raises(Resolver::Error) { r.resolve_bridge! }
  end

  def test_unresolved_bridge_raises_with_actionable_message
    r = Resolver.new(monorepo_root: File.join(@tmp, "nonexistent-monorepo"), disable_gem_discovery: true)
    err = assert_raises(Resolver::Error) { r.resolve_bridge! }
    assert_match(/@takahashim\/mruby-wasm-js bridge not found/, err.message)
    assert_match(/mruby_wasm_js_path/, err.message)
    assert_match(/MRUBY_WASM_JS_PATH/, err.message)
  end
end
