# frozen_string_literal: true

require_relative "test_helper"

# Ruby (wasmtime-rb + quickjs + Dommy) port of test/parity-runner.mjs:
# for each fixture, build it both `--target full` and `--target compiled`,
# drive the same user-action scenario against each, and assert the rendered
# DOM is byte-identical after every step — proving "same .lil → same DOM
# regardless of target".
#
# Slow (two `lilac build` per fixture + both wasm targets), so NOT in the
# default `rake test`; run via `make test-parity-rb` (kept alongside the Node
# `make test-parity` as a cross-check). Uses the dev wasms by default;
# LILAC_FULL_WASM / LILAC_COMPILED_WASM override.
class TestParity < Minitest::Test
  RUBY_SPEC_DIR = File.expand_path("../../test/ruby_spec", __dir__)
  require File.join(RUBY_SPEC_DIR, "mruby_wasm")
  require File.join(RUBY_SPEC_DIR, "runtime_build_helper")

  REPO          = File.expand_path("../..", __dir__)
  FULL_WASM     = ENV.fetch("LILAC_FULL_WASM", File.join(REPO, "build/lilac-full.wasm"))
  COMPILED_WASM = ENV.fetch("LILAC_COMPILED_WASM", File.join(REPO, "build/lilac-compiled.wasm"))
  FIXTURES_DIR  = File.join(REPO, "test/parity-fixtures")
  EXTRAS_MRBLIB = File.join(REPO, "runtime/mruby-lilac-extras/mrblib")

  # Per-fixture scenario: a component selector, the action steps (each drives
  # both VMs), and how to snapshot. Mirrors parity-runner.mjs's SCENARIOS.
  SCENARIOS = {
    "counter" => {
      selector: '[data-use="counter"]',
      steps: [
        ["initial mount", nil],
        ["click inc",    ->(t, vm) { t.click(vm, "inc") }],
        ["click inc x3", ->(t, vm) { 3.times { t.click(vm, "inc") } }],
        ["click dec x2", ->(t, vm) { 2.times { t.click(vm, "dec") } }],
      ],
    },
    "toggle" => {
      selector: '[data-use="toggle"]',
      steps: [
        ["initial mount", nil],
        ["click toggle (true)",  ->(t, vm) { t.click(vm, "toggle_btn") }],
        ["click toggle (false)", ->(t, vm) { t.click(vm, "toggle_btn") }],
        ["click toggle (true)",  ->(t, vm) { t.click(vm, "toggle_btn") }],
      ],
    },
    "form" => {
      selector: '[data-use="login-form"]',
      steps: [
        ["initial mount", nil],
        ["type email",     ->(t, vm) { t.type_into(vm, "email_input", "alice@example.com") }],
        ["type password",  ->(t, vm) { t.type_into(vm, "pw_input", "secret") }],
        ["click submit",   ->(t, vm) { t.click(vm, "submit") }],
        ["clear email",    ->(t, vm) { t.type_into(vm, "email_input", "") }],
        ["submit missing", ->(t, vm) { t.click(vm, "submit") }],
      ],
    },
    "list" => {
      selector: '[data-use="tag-list"]',
      # Generated lil-N synthetic refs differ across paths; normalise them.
      normalize: ->(html) { html.gsub(/data-ref="lil\d+"/, 'data-ref="lilN"') },
      steps: [
        ["initial mount", nil],
        ["click add",            ->(t, vm) { t.click(vm, "add") }],
        ["click add again",      ->(t, vm) { t.click(vm, "add") }],
        ["click remove first",   ->(t, vm) { t.click(vm, "remove_first") }],
        ["click reverse",        ->(t, vm) { t.click(vm, "reverse") }],
        ["remove first x2",      ->(t, vm) { 2.times { t.click(vm, "remove_first") } }],
      ],
    },
    "extras" => {
      selector: '[data-use="tooltip-widget"]',
      # The compiled wasm links no extras gem — load the package .mrb at runtime
      # (full ships extras, so loading only on compiled keeps both symmetric).
      compiled_packages: -> {
        RuntimeBuildHelper.build_package(
          %w[lilac_extras lilac_extras_focus lilac_extras_tooltip].map { |f| File.join(EXTRAS_MRBLIB, "#{f}.rb") },
          "extras.mrb",
        )
      },
      steps: [
        ["initial mount",  nil],
        ["click toggle",   ->(t, vm) { t.click(vm, "toggle") }],
        ["click toggle 2", ->(t, vm) { t.click(vm, "toggle") }],
      ],
    },
  }.freeze

  def setup
    skip "MRUBY_WASM_RUNTIME_PATH unset" unless ENV["MRUBY_WASM_RUNTIME_PATH"]
    skip "lilac-full.wasm not built" unless File.file?(FULL_WASM)
    skip "lilac-compiled.wasm not built" unless File.file?(COMPILED_WASM)
    skip "dommy-js-quickjs engine required" if ENV["LILAC_JS_ENGINE"] == "dommy-stub"
  end

  SCENARIOS.each_key do |fixture|
    define_method("test_parity_#{fixture}") { run_parity(fixture) }
  end

  # --- step helpers (called from scenario lambdas) ---

  def click(vm, ref)
    vm.document.query_selector(%([data-ref="#{ref}"])).click
    vm.drain_async!
  end

  def type_into(vm, ref, value)
    el = vm.document.query_selector(%([data-ref="#{ref}"]))
    el.value = value
    el.dispatch_event(Dommy::Event.new("input", bubbles: true))
    vm.drain_async!
  end

  private

  def run_parity(fixture)
    scenario = SCENARIOS.fetch(fixture)
    fixture_src = File.join(FIXTURES_DIR, fixture)

    full_dist     = RuntimeBuildHelper.build_fixture(fixture_src, "full")
    compiled_dist = RuntimeBuildHelper.build_fixture(fixture_src, "compiled")

    full_page     = RuntimeBuildHelper.read_dist_page(full_dist)
    compiled_page = RuntimeBuildHelper.read_dist_page(compiled_dist)
    full_seed     = RuntimeBuildHelper.body_seed(full_page)
    # Pre-flight: same source → same DOM seed, so a markup difference can't
    # masquerade as a runtime divergence.
    assert_equal full_seed.strip, RuntimeBuildHelper.body_seed(compiled_page).strip,
                 "dist body markup differs between targets (pre-flight)"

    packages = scenario[:compiled_packages] ? [scenario[:compiled_packages].call] : []

    full_vm = MrubyWasm.new(wasm_path: FULL_WASM)
    full_vm.document.body.inner_html = full_seed
    RuntimeBuildHelper.ruby_scripts(full_page).each { |src| full_vm.eval(src) }
    full_vm.drain_async!

    compiled_vm = MrubyWasm.new(wasm_path: COMPILED_WASM)
    compiled_vm.document.body.inner_html = full_seed
    packages.each { |path| compiled_vm.load_bytecode(File.binread(path)) }
    RuntimeBuildHelper.mrb_chain(compiled_dist).each { |path| compiled_vm.load_bytecode(File.binread(path)) }
    compiled_vm.drain_async!

    norm = scenario[:normalize] || ->(h) { h }
    scenario[:steps].each do |label, action|
      if action
        action.call(self, full_vm)
        action.call(self, compiled_vm)
      end
      a = norm.call(snapshot(full_vm, scenario[:selector]))
      b = norm.call(snapshot(compiled_vm, scenario[:selector]))
      assert_equal a, b, "#{fixture} DOM divergence after step: #{label}"
    end
  end

  def snapshot(vm, selector)
    el = vm.document.query_selector(selector)
    refute_nil el, "component #{selector} not mounted"
    el.outer_html
  end
end
