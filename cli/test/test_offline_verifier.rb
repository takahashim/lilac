# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class TestOfflineVerifier < Minitest::Test
  Verifier = Lilac::CLI::OfflineVerifier

  def setup
    @dist = Dir.mktmpdir("lilac-offline-test-")
  end

  def teardown
    FileUtils.remove_entry(@dist)
  end

  # Lay down the :full runtime assets a self-contained dist must have.
  def vendor_full_runtime!
    dir = File.join(@dist, "vendor", "lilac-full")
    FileUtils.mkdir_p(File.join(dir, "mruby-wasm-js"))
    File.write(File.join(dir, "lilac-full.wasm"), "WASM")
    File.write(File.join(dir, "mruby-wasm-js", "index.js"), "export const createVM = () => {};")
  end

  def write_dist(name, content)
    path = File.join(@dist, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def levels(results)
    results.map(&:level)
  end

  def test_self_contained_dist_has_no_violations
    vendor_full_runtime!
    write_dist("index.html", <<~HTML)
      <script type="module">
        import { createVM } from "/vendor/lilac-full/mruby-wasm-js/index.js";
        const vm = await createVM({ wasm: "/vendor/lilac-full/lilac-full.wasm" });
        await fetch("/lilac.packages.json");
      </script>
    HTML

    results = Verifier.new(@dist).verify
    assert_equal [:ok], levels(results)
  end

  def test_no_vendored_runtime_is_a_violation
    # No vendor dir at all → can't run offline.
    write_dist("index.html", "<html><body>hi</body></html>")

    results = Verifier.new(@dist).verify
    assert(results.any? { |r| r.level == :warn && r.message.include?("no vendored runtime") })
  end

  def test_incomplete_vendored_runtime_is_a_violation
    # vendor/lilac-full/ exists but the wasm is missing.
    dir = File.join(@dist, "vendor", "lilac-full", "mruby-wasm-js")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "index.js"), "export {};")
    write_dist("index.html", "<html></html>")

    results = Verifier.new(@dist).verify
    assert(results.any? { |r| r.level == :warn && r.message.include?("lilac-full.wasm") })
  end

  def test_remote_import_is_a_violation
    vendor_full_runtime!
    write_dist("index.html", <<~HTML)
      <script type="module">
        import { boot } from "https://takahashim.github.io/lilac/v0.1.0/index.js";
        await boot();
      </script>
    HTML

    results = Verifier.new(@dist).verify
    assert(results.any? { |r| r.level == :warn && r.message.include?("github.io") })
  end

  def test_protocol_relative_cdn_src_is_a_violation
    vendor_full_runtime!
    write_dist("page.html", '<script src="//cdn.example.com/x.js"></script>')

    results = Verifier.new(@dist).verify
    assert(results.any? { |r| r.level == :warn && r.message.include?("cdn.example.com") })
  end

  def test_outbound_anchor_link_is_allowed
    vendor_full_runtime!
    write_dist("index.html", <<~HTML)
      <script type="module">
        import { createVM } from "/vendor/lilac-full/mruby-wasm-js/index.js";
      </script>
      <a href="https://example.com/docs">External docs</a>
    HTML

    results = Verifier.new(@dist).verify
    assert_equal [:ok], levels(results)
  end

  def test_root_relative_and_relative_paths_are_allowed
    vendor_full_runtime!
    write_dist("index.html", <<~HTML)
      <link rel="stylesheet" href="/styles.css">
      <script type="module">
        import x from "./local.js";
        import { createVM } from "/vendor/lilac-full/mruby-wasm-js/index.js";
        await fetch("/lilac.packages.json");
      </script>
    HTML

    results = Verifier.new(@dist).verify
    assert_equal [:ok], levels(results)
  end

  def test_detects_compiled_runtime_dir
    # A :compiled dist (only the compiled vendor dir) is self-contained too.
    dir = File.join(@dist, "vendor", "lilac-compiled", "mruby-wasm-js")
    FileUtils.mkdir_p(dir)
    File.write(File.join(@dist, "vendor", "lilac-compiled", "lilac.wasm"), "WASM")
    File.write(File.join(dir, "index.js"), "export {};")
    write_dist("index.html", '<script type="module">import "/vendor/lilac-compiled/mruby-wasm-js/index.js";</script>')

    results = Verifier.new(@dist).verify
    assert_equal [:ok], levels(results)
  end
end
