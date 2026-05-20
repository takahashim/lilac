# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TestCommand < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("lilac-cmd-test")
    FileUtils.mkdir_p(File.join(@tmp, "components"))
    FileUtils.mkdir_p(File.join(@tmp, "pages"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def run_cmd(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Lilac::CLI::Command.new(argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  def test_build_succeeds_with_minimum_inputs
    File.write(File.join(@tmp, "components", "counter.lil"), <<~GNT)
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    File.write(File.join(@tmp, "pages", "index.html"), <<~HTML)
      <html><body><lilac-component name="counter"></lilac-component></body></html>
    HTML

    # `--target full` keeps the test mrbc-free; `lilac build` defaults
    # to `:compiled` which would require mrbc in the test environment.
    status, out, err = run_cmd("build", "--root", @tmp, "--target", "full")
    assert_equal 0, status, "stderr: #{err}"
    assert_match(/Built 1 page\(s\) from 1 component\(s\)/, out)
    assert File.exist?(File.join(@tmp, "dist", "index.html"))
  end

  def test_build_default_wipes_output_dir_before_building
    File.write(File.join(@tmp, "components", "counter.lil"), <<~GNT)
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    File.write(File.join(@tmp, "pages", "index.html"), <<~HTML)
      <html><body><lilac-component name="counter"></lilac-component></body></html>
    HTML

    dist = File.join(@tmp, "dist")
    FileUtils.mkdir_p(dist)
    stale = File.join(dist, "stale.txt")
    File.write(stale, "leftover from a previous build")

    # No `--clean` flag — default behavior is to wipe before build.
    # `--target full` to keep the test mrbc-free.
    status, _out, err = run_cmd("build", "--root", @tmp, "--target", "full")
    assert_equal 0, status, "stderr: #{err}"
    refute File.exist?(stale), "build must remove stale files in the output dir by default"
    assert File.exist?(File.join(dist, "index.html"))
  end

  def test_build_no_clean_preserves_existing_files
    File.write(File.join(@tmp, "components", "counter.lil"), <<~GNT)
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    File.write(File.join(@tmp, "pages", "index.html"), <<~HTML)
      <html><body><lilac-component name="counter"></lilac-component></body></html>
    HTML

    dist = File.join(@tmp, "dist")
    FileUtils.mkdir_p(dist)
    keep = File.join(dist, "external.txt")
    File.write(keep, "managed outside lilac")

    status, _out, err = run_cmd("build", "--root", @tmp, "--no-clean", "--target", "full")
    assert_equal 0, status, "stderr: #{err}"
    assert File.exist?(keep), "--no-clean must preserve pre-existing files in the output dir"
    assert File.exist?(File.join(dist, "index.html"))
  end

  def test_build_refuses_to_wipe_project_root
    File.write(File.join(@tmp, "components", "counter.lil"), <<~GNT)
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    File.write(File.join(@tmp, "pages", "index.html"), "<html><body></body></html>")

    # `--output @tmp` would make output_dir == project root. The guard
    # runs on every build now (default-clean), so no `--clean` flag is
    # needed to trigger it. `--target full` keeps the test mrbc-free.
    status, _out, err = run_cmd("build", "--root", @tmp, "--output", @tmp, "--target", "full")
    refute_equal 0, status, "must refuse to wipe a path that resolves to the project root"
    assert_match(/refused/, err)
  end

  def test_build_reports_unknown_component_via_stderr
    File.write(File.join(@tmp, "pages", "index.html"), <<~HTML)
      <html><body><lilac-component name="missing"></lilac-component></body></html>
    HTML

    status, _out, err = run_cmd("build", "--root", @tmp, "--target", "full")
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
      assert File.exist?(File.join(@tmp, "demoapp", "components", "counter.lil"))
    end
  end

  def test_new_without_name_returns_usage_error
    status, _out, err = run_cmd("new")
    refute_equal 0, status
    assert_match(/Usage: lilac new/, err)
  end

  def test_new_with_invalid_name_returns_error_via_stderr
    status, _out, err = run_cmd("new", "Bad-Name")
    refute_equal 0, status
    assert_match(/Invalid project name/, err)
  end

  def test_preview_errors_when_dist_missing
    # No `lilac build` was run, dist/ doesn't exist.
    status, _out, err = run_cmd("preview", "--root", @tmp)
    refute_equal 0, status, "preview must refuse to start without a built dist"
    assert_match(/does not exist|Run `lilac build`/, err)
  end

  def test_preview_errors_when_dist_has_no_html
    FileUtils.mkdir_p(File.join(@tmp, "dist"))
    # dist/ exists but contains no *.html.
    status, _out, err = run_cmd("preview", "--root", @tmp)
    refute_equal 0, status, "preview must refuse to start with empty dist"
    assert_match(/no HTML|Run `lilac build`/, err)
  end

  def test_preview_help_lists_options
    # Use the `help` subcommand (which returns rather than exiting) —
    # the inline `--help` flag invokes `exit 0` directly which is
    # harder to capture under Minitest.
    status, out, _err = run_cmd("help", "preview")
    assert_equal 0, status
    assert_match(/Usage: lilac preview/, out)
    assert_match(/--port/, out)
  end

  def test_help_lists_preview_command
    status, out, _err = run_cmd("help")
    assert_equal 0, status
    assert_match(/preview\s+Serve the built dist/, out)
  end
end
