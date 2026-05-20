# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestScaffold < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("lilac-scaffold-test")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_creates_expected_files
    files = Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    assert_includes files, ".gitignore"
    assert_includes files, "Gemfile"
    assert_includes files, "README.md"
    assert_includes files, "pages/index.html"
    assert_includes files, "components/counter.lil"
    assert_includes files, "public/.gitkeep"
    assert_includes files, "lilac.config.rb"
  end

  def test_writes_actual_files_to_disk
    Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    %w[.gitignore Gemfile README.md pages/index.html components/counter.lil public/.gitkeep lilac.config.rb].each do |rel|
      assert File.exist?(File.join(@tmp, "my-app", rel)), "missing: #{rel}"
    end
  end

  def test_config_template_is_all_commented_out
    Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    content = File.read(File.join(@tmp, "my-app", "lilac.config.rb"))
    # The `configure` block exists so the DSL contract is visible, but
    # every concrete setting is commented to keep defaults active.
    assert_match(/Lilac::CLI\.configure do \|c\|/, content)
    refute_match(/^  c\.\w/, content) # no uncommented `c.foo = ...` lines
  end

  def test_substitutes_project_name_in_readme
    Lilac::CLI::Scaffold.new("blogapp", root: @tmp).run
    content = File.read(File.join(@tmp, "blogapp", "README.md"))
    assert_includes content, "# blogapp"
    refute_includes content, "{{name}}"
  end

  def test_substitutes_project_name_in_index_html
    Lilac::CLI::Scaffold.new("blogapp", root: @tmp).run
    content = File.read(File.join(@tmp, "blogapp", "pages", "index.html"))
    assert_includes content, "<title>blogapp</title>"
    assert_includes content, "<h1>blogapp</h1>"
    refute_includes content, "{{name}}"
  end

  def test_counter_widget_is_complete_and_uses_succ_pred
    Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    content = File.read(File.join(@tmp, "my-app", "components", "counter.lil"))
    assert_includes content, "class Counter < Lilac::Component"
    assert_includes content, "&:succ"
    assert_includes content, "&:pred"
    assert_includes content, "<template>"
    assert_includes content, '<script type="text/ruby">'
  end

  def test_destination_already_exists_raises
    FileUtils.mkdir_p(File.join(@tmp, "my-app"))
    err = assert_raises(Lilac::CLI::Scaffold::Error) do
      Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    end
    assert_match(/already exists/, err.message)
  end

  def test_invalid_name_raises
    err = assert_raises(Lilac::CLI::Scaffold::Error) do
      Lilac::CLI::Scaffold.new("My-App", root: @tmp).run
    end
    assert_match(/Invalid project name/, err.message)
  end

  def test_empty_name_raises
    err = assert_raises(Lilac::CLI::Scaffold::Error) do
      Lilac::CLI::Scaffold.new("", root: @tmp).run
    end
    assert_match(/required/, err.message)
  end

  def test_name_starting_with_digit_raises
    err = assert_raises(Lilac::CLI::Scaffold::Error) do
      Lilac::CLI::Scaffold.new("1app", root: @tmp).run
    end
    assert_match(/Invalid project name/, err.message)
  end

  def test_gitignore_is_dot_prefixed_in_output
    Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    assert File.exist?(File.join(@tmp, "my-app", ".gitignore"))
    refute File.exist?(File.join(@tmp, "my-app", "gitignore"))
  end

  def test_gemfile_declares_lilac_cli_and_wasm_bin
    Lilac::CLI::Scaffold.new("my-app", root: @tmp).run
    gemfile = File.read(File.join(@tmp, "my-app", "Gemfile"))
    # lilac-cli is the build tool; lilac-wasm-bin ships the runtime
    # wasm + bridge so `bundle install` is enough to make `lilac dev`
    # and `lilac build` work without npm.
    assert_match(/gem ["']lilac-cli["']/, gemfile)
    assert_match(/gem ["']lilac-wasm-bin["']/, gemfile)
  end

  def test_generated_project_builds_with_builder
    # End-to-end sanity: the scaffold must produce a project that
    # `lilac build` happily compiles. Catches drift between Scaffold
    # templates and Builder expectations (placeholder syntax, file
    # layout, etc.).
    Lilac::CLI::Scaffold.new("smoke", root: @tmp).run
    dest = File.join(@tmp, "smoke")
    # Drop a sample static file so we can verify public/ passthrough
    # works end-to-end through the scaffolded layout.
    File.write(File.join(dest, "public", "favicon.txt"), "stub")

    Lilac::CLI::Builder.new(
      components_dir: File.join(dest, "components"),
      pages_dir: File.join(dest, "pages"),
      output_dir: File.join(dest, "dist"),
      public_dir: File.join(dest, "public"),
    ).build
    out = File.read(File.join(dest, "dist", "index.html"))
    assert_includes out, 'data-component="counter"'
    assert_includes out, "class Counter < Lilac::Component"
    # public/ passthrough delivers favicon.txt to dist/, but the .gitkeep
    # placeholder is filtered out.
    assert_equal "stub", File.read(File.join(dest, "dist", "favicon.txt"))
    refute File.exist?(File.join(dest, "dist", ".gitkeep"))
  end
end
