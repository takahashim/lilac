# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestConfig < Minitest::Test
  def test_defaults_to_cwd_when_root_nil
    # Regression: passing `root: nil` (from un-set CLI flag) must fall
    # back to Dir.pwd rather than blowing up on File.expand_path(nil).
    config = Lilac::CLI::Config.new(root: nil)
    assert_equal File.expand_path(Dir.pwd), config.root
  end

  def test_defaults_to_cwd_when_root_omitted
    config = Lilac::CLI::Config.new
    assert_equal File.expand_path(Dir.pwd), config.root
  end

  def test_widgets_pages_output_default_relative_to_root
    config = Lilac::CLI::Config.new(root: "/tmp/proj")
    assert_equal "/tmp/proj", config.root
    assert_equal "/tmp/proj/components", config.components_dir
    assert_equal "/tmp/proj/pages", config.pages_dir
    assert_equal "/tmp/proj/dist", config.output_dir
    assert_equal "/tmp/proj/public", config.public_dir
  end

  def test_explicit_dirs_override_defaults
    config = Lilac::CLI::Config.new(
      root: "/tmp/proj",
      components_dir: "components",
      output_dir: "../out",
    )
    assert_equal "/tmp/proj/components", config.components_dir
    assert_equal "/tmp/out", config.output_dir
  end

  def test_default_packages_is_empty_array
    config = Lilac::CLI::Config.new
    assert_equal [], config.packages
  end

  def test_packages_paths_are_expanded_against_root
    config = Lilac::CLI::Config.new(
      root: "/tmp/proj",
      packages: ["vendor/local-fork/foo.mrb"],
    )
    assert_equal(
      ["/tmp/proj/vendor/local-fork/foo.mrb"],
      config.packages,
    )
  end

  def test_packages_absolute_paths_pass_through
    config = Lilac::CLI::Config.new(
      root: "/tmp/proj",
      packages: ["/abs/pkg.mrb"],
    )
    assert_equal ["/abs/pkg.mrb"], config.packages
  end

  def test_default_dev_host_and_port
    config = Lilac::CLI::Config.new
    assert_equal "127.0.0.1", config.dev_host
    assert_equal 5173, config.dev_port
  end

  # ---- Config.load: three-way merge tests ----

  def setup
    @tmp = Dir.mktmpdir("lilac-config-load")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp
  end

  def write_config(content)
    File.write(File.join(@tmp, "lilac.config.rb"), content)
  end

  def test_load_without_file_falls_back_to_defaults
    config = Lilac::CLI::Config.load(root: @tmp)
    assert_equal File.join(@tmp, "components"), config.components_dir
    assert_equal 5173, config.dev_port
  end

  def test_load_uses_config_file_when_no_cli_override
    write_config <<~RB
      Lilac::CLI.configure do |c|
        c.components_dir = "components"
        c.dev_port    = 4000
      end
    RB
    config = Lilac::CLI::Config.load(root: @tmp)
    assert_equal File.join(@tmp, "components"), config.components_dir
    assert_equal 4000, config.dev_port
  end

  def test_load_cli_overrides_file
    write_config <<~RB
      Lilac::CLI.configure do |c|
        c.components_dir = "from-file"
        c.dev_port    = 4000
      end
    RB
    config = Lilac::CLI::Config.load(root: @tmp, components_dir: "from-cli", dev_port: 9999)
    assert_equal File.join(@tmp, "from-cli"), config.components_dir
    assert_equal 9999, config.dev_port
  end

  def test_load_falls_through_to_defaults_for_fields_neither_in_file_nor_cli
    write_config <<~RB
      Lilac::CLI.configure do |c|
        c.dev_port = 4000
      end
    RB
    config = Lilac::CLI::Config.load(root: @tmp)
    # dev_port comes from file:
    assert_equal 4000, config.dev_port
    # components_dir not set anywhere — built-in default applies:
    assert_equal File.join(@tmp, "components"), config.components_dir
  end
end
