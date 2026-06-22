# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

# Shared host-side helpers for the bundle / parity runtime specs: build a
# fixture project with `lilac build`, then split the produced dist into the
# DOM seed + the runtime payload (inline Ruby for :full, `.mrb` for :compiled).
#
# These replace the build/dist plumbing of test/bundle-runtime.mjs and
# test/parity-runner.mjs; the DOM is driven on the quickjs+Dommy runtime
# (MrubyWasm#document) instead of Node + happy-dom.
module RuntimeBuildHelper
  module_function

  REPO        = File.expand_path("../..", __dir__)
  LILAC_BIN   = File.join(REPO, "cli/exe/lilac")
  CLI_GEMFILE = File.join(REPO, "cli/Gemfile")

  def mwr_root
    ENV.fetch("MRUBY_WASM_RUNTIME_PATH") {
      raise "MRUBY_WASM_RUNTIME_PATH must point at a mruby-wasm-runtime checkout"
    }
  end

  # Build `fixture_src` with the given target into a fresh tmpdir. `config`
  # (when given) is written as lilac.config.rb before building (e.g. to opt
  # into `delivery = :bundle`). Returns the project dir (dist is under dist/).
  def build_fixture(fixture_src, target, config: nil)
    dest = Dir.mktmpdir("lilac-rt-#{target}-")
    FileUtils.cp_r(File.join(fixture_src, "."), dest)
    File.write(File.join(dest, "lilac.config.rb"), config) if config
    env = {
      "MRUBY_WASM_RUNTIME_PATH" => mwr_root,
      "BUNDLE_GEMFILE" => CLI_GEMFILE,
    }
    out, status = Open3.capture2e(env, LILAC_BIN, "build", "--target", target, chdir: dest)
    raise "lilac build --target #{target} failed in #{dest}:\n#{out}" unless status.success?

    File.join(dest, "dist")
  end

  # The <body> inner markup with all <script> blocks stripped (the DOM seed),
  # prefixed with the `<link rel="lilac-bundle">` (which lives in <head> in the
  # emitted page) so a bundle boot's whole-document scan still finds it.
  def body_seed(page_html)
    inner = page_html[/<body[^>]*>(.*?)<\/body>/im, 1] || page_html
    body = inner.gsub(/<script.*?<\/script>/im, "")
    link = page_html[/<link[^>]*rel="lilac-bundle"[^>]*>/i] || ""
    link + body
  end

  # Inline Ruby from every <script type="text/ruby"> in the html.
  def ruby_scripts(html)
    html.scan(/<script type="text\/ruby">(.*?)<\/script>/im).map(&:first)
  end

  # Absolute paths to the dist `.mrb` files, in boot order: the page's boot
  # module fetches them as `./NAME.mrb`, so honor that sequence (definitions
  # before the start mrb). Falls back to a lexical sort if none are referenced.
  def mrb_chain(dist_dir)
    page = File.read(File.join(dist_dir, "index.html"))
    names = page.scan(/fetch\("\.\/([^"]+\.mrb)"\)/).map(&:first)
    names = Dir.children(dist_dir).select { |f| f.end_with?(".mrb") }.sort if names.empty?
    names.map { |n| File.join(dist_dir, n) }
  end

  def read_dist_page(dist_dir)
    File.read(File.join(dist_dir, "index.html"))
  end

  # Compile a package `.mrb` from mrblib sources via `lilac package-build`
  # (same path users hit: concat mrblib → mrbc backend). Returns the out path.
  def build_package(sources, basename)
    dest = Dir.mktmpdir("lilac-rt-pkg-")
    out = File.join(dest, basename)
    env = {"MRUBY_WASM_RUNTIME_PATH" => mwr_root, "BUNDLE_GEMFILE" => CLI_GEMFILE}
    stdout, status = Open3.capture2e(env, LILAC_BIN, "package-build", *sources, "-o", out)
    raise "lilac package-build failed:\n#{stdout}" unless status.success?

    out
  end
end
