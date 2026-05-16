# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TestCommand < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("grainet-cmd-test")
    FileUtils.mkdir_p(File.join(@tmp, "components"))
    FileUtils.mkdir_p(File.join(@tmp, "pages"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def run_cmd(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Grainet::CLI::Command.new(argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  def test_build_succeeds_with_minimum_inputs
    File.write(File.join(@tmp, "components", "counter.gnt"), <<~GNT)
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Grainet::Component; end</script>
    GNT

    File.write(File.join(@tmp, "pages", "index.html"), <<~HTML)
      <html><body><grainet-component name="counter"></grainet-component></body></html>
    HTML

    status, out, err = run_cmd("build", "--root", @tmp)
    assert_equal 0, status, "stderr: #{err}"
    assert_match(/Built 1 page\(s\) from 1 component\(s\)/, out)
    assert File.exist?(File.join(@tmp, "dist", "index.html"))
  end

  def test_build_reports_unknown_component_via_stderr
    File.write(File.join(@tmp, "pages", "index.html"), <<~HTML)
      <html><body><grainet-component name="missing"></grainet-component></body></html>
    HTML

    status, _out, err = run_cmd("build", "--root", @tmp)
    refute_equal 0, status
    assert_match(/Unknown component: "missing"/, err)
  end

  def test_unknown_subcommand_returns_nonzero_and_prints_help
    status, _out, err = run_cmd("nope")
    assert_equal 1, status
    assert_match(/unknown command "nope"/, err)
    assert_match(/Usage:/, err)
  end

  def test_help_returns_zero
    status, out, _err = run_cmd("help")
    assert_equal 0, status
    assert_match(/Usage:/, out)
  end

  def test_new_scaffolds_into_cwd
    Dir.chdir(@tmp) do
      status, out, _err = run_cmd("new", "demoapp")
      assert_equal 0, status
      assert_match(/Created demoapp\//, out)
      assert_match(/Next steps:/, out)
      assert File.exist?(File.join(@tmp, "demoapp", "components", "counter.gnt"))
    end
  end

  def test_new_without_name_returns_usage_error
    status, _out, err = run_cmd("new")
    refute_equal 0, status
    assert_match(/Usage: grainet new/, err)
  end

  def test_new_with_invalid_name_returns_error_via_stderr
    status, _out, err = run_cmd("new", "Bad-Name")
    refute_equal 0, status
    assert_match(/Invalid project name/, err)
  end
end
