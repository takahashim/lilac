# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TestDoctor < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("lilac-doctor-test")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def run_doctor(lilac_compiled_path: nil)
    out = StringIO.new
    config = Lilac::CLI::Config.new(root: @tmp, lilac_compiled_path: lilac_compiled_path)
    status = Lilac::CLI::Doctor.new(config, out: out).run
    [status, out.string]
  end

  def scaffold_minimal_project
    FileUtils.mkdir_p(File.join(@tmp, "pages"))
    FileUtils.mkdir_p(File.join(@tmp, "components"))
    FileUtils.mkdir_p(File.join(@tmp, "public", "vendor", "lilac-full", "mruby-wasm-js"))
    File.write(File.join(@tmp, "pages", "index.html"),
               '<html><body><lilac-component name="counter"></lilac-component></body></html>')
    File.write(File.join(@tmp, "components", "counter.lil"), <<~GNT)
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    File.write(File.join(@tmp, "public", "vendor", "lilac-full", "lilac-full.wasm"), "WASM")
    File.write(File.join(@tmp, "public", "vendor", "lilac-full", "mruby-wasm-js", "index.js"), "export {}")
  end

  def test_passes_on_fully_set_up_project
    scaffold_minimal_project
    status, out = run_doctor
    assert_equal 0, status, out
    assert_match(/0 error\(s\)/, out)
  end

  def test_fails_when_pages_dir_missing
    # components/, public/ etc. don't exist either, but the first failing
    # check we care about is pages/.
    status, out = run_doctor
    refute_equal 0, status
    assert_match(/\[FAIL\].*pages\/ directory missing/, out)
  end

  def test_fails_when_runtime_wasm_missing
    scaffold_minimal_project
    FileUtils.rm(File.join(@tmp, "public", "vendor", "lilac-full", "lilac-full.wasm"))

    status, out = run_doctor
    refute_equal 0, status
    assert_match(/\[FAIL\].*mruby-wasm runtime missing/, out)
  end

  def test_fails_when_js_adapter_missing
    scaffold_minimal_project
    FileUtils.rm(File.join(@tmp, "public", "vendor", "lilac-full", "mruby-wasm-js", "index.js"))

    status, out = run_doctor
    refute_equal 0, status
    assert_match(/\[FAIL\].*JS adapter missing/, out)
  end

  def test_fails_when_page_references_unknown_widget
    scaffold_minimal_project
    File.write(File.join(@tmp, "pages", "other.html"),
               '<html><body><lilac-component name="ghost"></lilac-component></body></html>')

    status, out = run_doctor
    refute_equal 0, status
    assert_match(/no components\/ghost\.lil exists/, out)
  end

  def test_warns_on_unused_widget
    scaffold_minimal_project
    File.write(File.join(@tmp, "components", "spare.lil"), <<~GNT)
      <template><div data-component="spare"></div></template>
      <script type="text/ruby">class Spare < Lilac::Component; end</script>
    GNT

    status, out = run_doctor
    assert_equal 0, status, "warning should not fail the run"
    assert_match(/\[WARN\].*unused components: spare/, out)
  end

  def test_fails_on_widget_parse_error
    scaffold_minimal_project
    File.write(File.join(@tmp, "components", "broken.lil"), "<template>unterminated")

    status, out = run_doctor
    refute_equal 0, status
    assert_match(/\[FAIL\].*component parse error.*broken\.lil/, out)
  end

  def test_summary_line_counts_results
    scaffold_minimal_project
    status, out = run_doctor
    # Roughly: 2 dirs + 1 component parses + references-ok + unused-ok +
    # public + wasm + adapter = 8 ok-ish results. Exact count is brittle;
    # just assert format presence.
    assert_match(/\d+ ok, \d+ warning\(s\), \d+ error\(s\)/, out)
    assert_equal 0, status
  end

  def test_compiled_runtime_reports_ok_when_discoverable
    scaffold_minimal_project
    fake = File.join(@tmp, "fake-lilac-compiled.wasm")
    File.binwrite(fake, "wasm")

    status, out = run_doctor(lilac_compiled_path: fake)
    assert_equal 0, status, out
    assert_match(/\[OK\].*compiled wasm discoverable/, out)
  end

  def test_compiled_runtime_warns_when_undiscoverable
    scaffold_minimal_project
    # Point at a nonexistent path AND override the gem-relative monorepo
    # so the resolver's fallback chain produces a clean "not found".
    # Doctor's instantiation of the resolver doesn't accept
    # monorepo_root: directly — we simulate via an explicit config path
    # that doesn't exist; the resolver then walks its other lookups.
    # On CI / monorepo machines without `build/lilac-compiled.wasm`,
    # this naturally lands in the warn branch.
    skip "needs a sandboxed monorepo to be deterministic; covered by resolver tests"
  end
end
