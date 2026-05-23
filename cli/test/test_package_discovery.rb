# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestPackageDiscovery < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("lilac-package-discovery-test")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  # Build a `Gem::Specification` stand-in matching enough of the real
  # API surface for `PackageDiscovery` to inspect. Easier than spinning
  # up a real Bundler context in tests.
  FakeSpec = Struct.new(:name, :version, :metadata, :full_gem_path, keyword_init: true)

  def stub_bundler_specs(specs)
    fake_bundler = Module.new
    fake_load = Object.new
    fake_load.define_singleton_method(:specs) { specs }
    fake_bundler.define_singleton_method(:load) { fake_load }
    # Re-bind the top-level `Bundler` constant for the duration of the
    # block so PackageDiscovery sees our stub instead of any real one
    # that minitest's gem activations may have wired up.
    saved = Object.const_defined?(:Bundler) ? Object.const_get(:Bundler) : nil
    Object.send(:remove_const, :Bundler) if Object.const_defined?(:Bundler)
    Object.const_set(:Bundler, fake_bundler)
    yield
  ensure
    Object.send(:remove_const, :Bundler) if Object.const_defined?(:Bundler)
    Object.const_set(:Bundler, saved) if saved
  end

  def make_package_gem(name, mrblib_files)
    base = File.join(@tmp, name)
    FileUtils.mkdir_p(File.join(base, "mrblib"))
    mrblib_files.each do |fname, content|
      File.write(File.join(base, "mrblib", fname), content)
    end
    FakeSpec.new(
      name: name,
      version: "0.1.0",
      metadata: { "lilac_package" => "true" },
      full_gem_path: base,
    )
  end

  def test_returns_empty_when_no_packages_in_bundle
    stub_bundler_specs([]) do
      assert_empty Lilac::CLI::PackageDiscovery.run
    end
  end

  def test_returns_empty_when_no_specs_have_lilac_package_metadata
    other = FakeSpec.new(
      name: "some-other-gem",
      version: "1.0.0",
      metadata: { "rubygems_mfa_required" => "true" },
      full_gem_path: @tmp,
    )
    stub_bundler_specs([other]) do
      assert_empty Lilac::CLI::PackageDiscovery.run
    end
  end

  def test_picks_up_package_gems_and_lists_mrblib_files
    package = make_package_gem("lilac-foo", {
                                 "a.rb" => "# a",
                                 "b.rb" => "# b",
                               })
    stub_bundler_specs([package]) do
      results = Lilac::CLI::PackageDiscovery.run
      assert_equal 1, results.length
      assert_equal "lilac-foo", results.first.name
      assert_equal "0.1.0", results.first.version
      assert_equal 2, results.first.mrblib_files.length
      # Alphabetical so concatenation is deterministic.
      basenames = results.first.mrblib_files.map { |p| File.basename(p) }
      assert_equal %w[a.rb b.rb], basenames
    end
  end

  def test_skips_package_gem_with_empty_mrblib
    empty_package = FakeSpec.new(
      name: "lilac-empty",
      version: "0.1.0",
      metadata: { "lilac_package" => "true" },
      full_gem_path: File.join(@tmp, "empty"),
    )
    # `full_gem_path` exists but no mrblib/ dir → no source to compile.
    # Skipping rather than erroring keeps a borked package from breaking
    # the whole build; the user still sees no .mrb produced from this gem.
    FileUtils.mkdir_p(empty_package.full_gem_path)
    stub_bundler_specs([empty_package]) do
      assert_empty Lilac::CLI::PackageDiscovery.run
    end
  end

  def test_returns_empty_when_bundler_not_loaded
    # Save and remove Bundler entirely so `defined?(Bundler)` is false.
    saved = Object.const_defined?(:Bundler) ? Object.const_get(:Bundler) : nil
    Object.send(:remove_const, :Bundler) if Object.const_defined?(:Bundler)
    begin
      assert_empty Lilac::CLI::PackageDiscovery.run
    ensure
      Object.const_set(:Bundler, saved) if saved
    end
  end
end
