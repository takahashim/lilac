# frozen_string_literal: true

require_relative "mruby_wasm"

# Drives the pure-mruby subset of Lilac's wasm_spec test suite through
# `lilac-full-host.wasm` + wasmtime-rb (replacing `node test/runner.mjs`
# for these specs). DOM / async specs stay on the Node runner — see
# the PURE_SPECS allow-list below for the boundary.
#
# Usage from Ruby:
#   results = SpecRunner.new.run
#   exit(results.failures.zero? ? 0 : 1)
#
# Usage from Minitest (recommended): see test_wasm_specs.rb.
class SpecRunner
  LILAC_ROOT = File.expand_path("../..", __dir__)
  MWR_ROOT   = ENV.fetch("MRUBY_WASM_RUNTIME_PATH") {
    raise "MRUBY_WASM_RUNTIME_PATH must point at a mruby-wasm-runtime checkout"
  }
  SPEC_HELPER = File.join(MWR_ROOT, "mrbgem/mruby-wasm-js/wasm_spec/spec_helper.rb")

  # Spec files that don't touch DOM / require async fibers — the
  # subset the Ruby runner can handle. Verified manually 2026-05-20:
  # each file uses only Ruby semantics + Spec.assert framework.
  # DOM-touching specs (test_bind_*, test_component_*, test_directive_*,
  # etc.) stay on the Node runner because no Ruby-equivalent DOM
  # polyfill exists.
  PURE_SPECS = [
    "runtime/mruby-regexp-compat/wasm_spec/test_regexp_string_api.rb",
    "runtime/mruby-regexp-compat/wasm_spec/test_regexp_edge_cases.rb",
    "runtime/mruby-regexp-compat/wasm_spec/test_regexp_regression.rb",
    "runtime/mruby-regexp-compat/wasm_spec/test_regexp_advanced.rb",
    "runtime/mruby-lilac/wasm_spec/test_signal.rb",
    "runtime/mruby-lilac/wasm_spec/test_computed.rb",
    "runtime/mruby-lilac/wasm_spec/test_effect.rb",
    "runtime/mruby-lilac/wasm_spec/test_untrack.rb",
    "runtime/mruby-lilac/wasm_spec/test_html.rb",
    "runtime/mruby-lilac/wasm_spec/test_json.rb",
    "runtime/mruby-lilac/wasm_spec/test_sortable.rb",
    "runtime/mruby-lilac-async/wasm_spec/test_selector.rb",
    # Session 9 unlock attempt — smallest DOM spec (31 lines).
    # Requires Lilac.start + MutationObserver + bind html: signal +
    # `JS.eval_javascript("new Promise(...)").await` drain.
    "runtime/mruby-lilac/wasm_spec/test_directive_unsafe_html.rb",
    # Session 10 batch — directive / component / bind / prop 系がまとめて
    # unlock (foundation 8 session 投資の最大の回収場面)。同パターンの
    # `Lilac.start + bind + .await(setTimeout(0))` で動く spec を一気に
    # PURE_SPECS に積み増し。
    "runtime/mruby-lilac/wasm_spec/test_directive_text.rb",
    "runtime/mruby-lilac/wasm_spec/test_directive_attr.rb",
    "runtime/mruby-lilac/wasm_spec/test_directive_class.rb",
    "runtime/mruby-lilac/wasm_spec/test_directive_show_hide.rb",
    "runtime/mruby-lilac/wasm_spec/test_directive_css.rb",
    "runtime/mruby-lilac/wasm_spec/test_directive_on.rb",
    "runtime/mruby-lilac/wasm_spec/test_bind_attr.rb",
    "runtime/mruby-lilac/wasm_spec/test_bind_template_hook.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_mount.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_autoregister.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_nested.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_dynamic.rb",
    "runtime/mruby-lilac/wasm_spec/test_set_style.rb",
    "runtime/mruby-lilac/wasm_spec/test_expose_lookup.rb",
    "runtime/mruby-lilac/wasm_spec/test_error_boundary.rb",
    "runtime/mruby-lilac/wasm_spec/test_prop_as_ivar.rb",
    "runtime/mruby-lilac/wasm_spec/test_prop_ivar_override_detection.rb",
    "runtime/mruby-lilac/wasm_spec/test_props.rb",
    # Session 11 unlock — element の反射プロパティ (hidden / disabled /
    # checked / className / value / id) + 属性名 lowercase 正規化を追加
    # した結果で取れた spec
    "runtime/mruby-lilac/wasm_spec/test_bind.rb",
    "runtime/mruby-lilac/wasm_spec/test_bind_class_style.rb",
    "runtime/mruby-lilac/wasm_spec/test_bind_input.rb",
    "runtime/mruby-lilac/wasm_spec/test_url_sanitizer.rb",
    # Session 12 unlock — replaceChild / parentNode / LiveChildren +
    # Parser.fragment が owner_doc を受けるよう改修 (libxml2 が cross-doc
    # add_child でノードを copy する挙動への対処)
    "runtime/mruby-lilac/wasm_spec/test_bind_list.rb",
    "runtime/mruby-lilac/wasm_spec/test_template.rb",
    # Session 13 unlock — localStorage / AbortController polyfill +
    # drain_async! が eval 後に full timer drain するよう拡張 (16ms 等の
    # setTimeout も自動進行)
    "runtime/mruby-lilac/wasm_spec/test_persistent_signal.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_abort.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_timer.rb",
    "runtime/mruby-lilac/wasm_spec/test_component_each_frame.rb",
    # Session 14 unlock — template content を独立 fragment に reparent
    # する refactor で template 配下が querySelector から見えなくなる
    "runtime/mruby-lilac/wasm_spec/test_directive_each.rb",
    "runtime/mruby-lilac/wasm_spec/test_node_operations.rb",
    # Session 15 unlock — mruby-lilac-form / mruby-lilac-directives /
    # mruby-lilac-async (test_selector 既存) を probe pass で一括追加
    "runtime/mruby-lilac-form/wasm_spec/test_form.rb",
    "runtime/mruby-lilac-form/wasm_spec/test_form_cross_field.rb",
    "runtime/mruby-lilac-form/wasm_spec/test_form_phase_a.rb",
    "runtime/mruby-lilac-form/wasm_spec/test_form_validators.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_codegen_parity_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_attr_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_bare_ident_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_bind_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_class_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_css_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_each_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_each_with_component_row.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_field_wiring.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_form_field_button.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_on_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_prop_expression.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_show_hide_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_directive_text_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_scanner_walk_runtime.rb",
    "runtime/mruby-lilac-directives/wasm_spec/test_smoke_runtime.rb",
    # Session 16-17 unlock — fetch polyfill (FetchFn/Response/Headers) +
    # encodeURIComponent + Array.from + 多名前 stub map + setTimeout
    # 経由の external abort pattern recognition
    "runtime/mruby-lilac-async/wasm_spec/test_fetchy.rb",
    "runtime/mruby-lilac-async/wasm_spec/test_resource.rb",
    "runtime/mruby-lilac-async/wasm_spec/test_resource_signal_inject.rb",
  ].freeze

  Result = Struct.new(:spec_path, :rc, :stdout, :stderr, :pass, :fail) do
    def ok?
      rc.zero? && fail.zero?
    end
  end

  def initialize(specs: PURE_SPECS, wasm_path: nil)
    @specs = specs
    @wasm_path = wasm_path || MrubyWasm::DEFAULT_WASM_PATH
  end

  attr_reader :results

  # Runs each spec in its own fresh wasm instance so per-spec state
  # (signals, effects, registered subscribers) doesn't bleed. Returns
  # an Array<Result>. Caller can inspect or pretty-print.
  def run
    @results = @specs.map { |spec| run_one(spec) }
  end

  def failures
    @results.count { |r| !r.ok? }
  end

  def pretty_print
    @results.each do |r|
      mark = r.ok? ? "OK  " : "FAIL"
      label = r.spec_path.sub("#{LILAC_ROOT}/", "")
      puts "[#{mark}] #{label}  pass=#{r.pass} fail=#{r.fail}"
      next if r.ok?

      r.stdout.lines.grep(/^\[FAIL\]| - /).each { |l| puts "    #{l.chomp}" }
      puts "    stderr: #{r.stderr.strip}" unless r.stderr.strip.empty?
    end
    puts
    puts "#{@results.size - failures}/#{@results.size} spec files pass"
  end

  private

  def run_one(spec_path)
    abs = File.join(LILAC_ROOT, spec_path)
    vm = MrubyWasm.new(wasm_path: @wasm_path)
    rc_helper = vm.eval(File.read(SPEC_HELPER))
    raise "spec_helper failed to load: rc=#{rc_helper}" unless rc_helper.zero?

    rc_spec = vm.eval(File.read(abs))
    vm.eval("Spec.summary")
    out = vm.stdout
    err = vm.stderr
    pass, fail = parse_summary(out)
    Result.new(abs, rc_spec, out, err, pass, fail)
  end

  # Spec.summary's last informational line is "X/Y tests pass (Z
  # assertions)". A spec file is failed if any group line starts with
  # "[FAIL]" — counting per-group results.
  def parse_summary(out)
    pass = 0
    fail = 0
    out.each_line do |line|
      next unless (m = line.match(/^\[(OK  |FAIL)\] .+: (\d+)\/(\d+)/))

      assertions_ok = m[2].to_i
      assertions_total = m[3].to_i
      pass += assertions_ok
      fail += (assertions_total - assertions_ok)
    end
    [pass, fail]
  end
end

if $PROGRAM_NAME == __FILE__
  runner = SpecRunner.new
  runner.run
  runner.pretty_print
  exit(runner.failures.zero? ? 0 : 1)
end
