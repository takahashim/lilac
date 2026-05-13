# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestConfigLoader < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("grainet-config-loader-test")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_config(content)
    File.write(File.join(@tmp, "grainet.config.rb"), content)
  end

  def test_returns_nil_when_no_config_file
    assert_nil Grainet::CLI::ConfigLoader.load(@tmp)
  end

  def test_loads_settings_from_full_config
    write_config <<~RB
      Grainet::CLI.configure do |c|
        c.widgets_dir = "src/components"
        c.pages_dir   = "src/pages"
        c.public_dir  = "static"
        c.output_dir  = "_site"
        c.dev_host    = "0.0.0.0"
        c.dev_port    = 3000
      end
    RB

    s = Grainet::CLI::ConfigLoader.load(@tmp)
    assert_equal "src/components", s.widgets_dir
    assert_equal "src/pages", s.pages_dir
    assert_equal "static", s.public_dir
    assert_equal "_site", s.output_dir
    assert_equal "0.0.0.0", s.dev_host
    assert_equal 3000, s.dev_port
  end

  def test_partial_config_leaves_other_fields_nil
    write_config <<~RB
      Grainet::CLI.configure do |c|
        c.dev_port = 8000
      end
    RB

    s = Grainet::CLI::ConfigLoader.load(@tmp)
    assert_equal 8000, s.dev_port
    assert_nil s.widgets_dir
    assert_nil s.dev_host
  end

  def test_empty_configure_block_returns_blank_settings
    write_config "Grainet::CLI.configure { |_c| }"
    s = Grainet::CLI::ConfigLoader.load(@tmp)
    assert_nil s.widgets_dir
    assert_nil s.dev_port
  end

  def test_syntax_error_raises_load_error
    write_config "this is not valid ruby ::: :::"
    err = assert_raises(Grainet::CLI::ConfigLoader::LoadError) do
      Grainet::CLI::ConfigLoader.load(@tmp)
    end
    assert_match(/Error loading grainet.config.rb/, err.message)
  end

  def test_configure_called_outside_load_raises
    # Sanity check on the DSL guard: the configure hook only works
    # while ConfigLoader.load is on the stack.
    err = assert_raises(Grainet::CLI::ConfigLoader::LoadError) do
      Grainet::CLI.configure { |_c| }
    end
    assert_match(/must be called from grainet.config.rb/, err.message)
  end

  def test_thread_isolation_does_not_leak_across_loads
    # Two consecutive loads should each see their own Settings; no
    # carry-over from a previous load's state.
    write_config "Grainet::CLI.configure { |c| c.dev_port = 1111 }"
    s1 = Grainet::CLI::ConfigLoader.load(@tmp)

    write_config "Grainet::CLI.configure { |c| c.dev_port = 2222 }"
    s2 = Grainet::CLI::ConfigLoader.load(@tmp)

    assert_equal 1111, s1.dev_port
    assert_equal 2222, s2.dev_port
  end
end
