# frozen_string_literal: true

require_relative "test_helper"

# Ruby (wasmtime-rb + quickjs + Dommy) port of test/bundle-runtime.mjs —
# the BOOT-TIME behavior of :bundle delivery (ADR-0030): fetch the
# `<link rel="lilac-bundle">`, inject its <template> elements into the live
# document, then run the payload and assert the data-use component mounts and
# stays reactive.
#
# Unlike the Node version, the real Dommy DOMParser keeps a <template>'s
# `.content` across cloning, so there is no happy-dom cross-document
# workaround — templates are injected straight into the live document.
#
# Slow (two `lilac build` invocations + both wasm targets), so it is NOT in the
# default `rake test`; run via `make test-bundle-rb` (kept alongside the Node
# `make test-bundle` as a cross-check).
class TestBundleRuntime < Minitest::Test
  RUBY_SPEC_DIR = File.expand_path("../../test/ruby_spec", __dir__)
  require File.join(RUBY_SPEC_DIR, "mruby_wasm")
  require File.join(RUBY_SPEC_DIR, "runtime_build_helper")

  REPO          = File.expand_path("../..", __dir__)
  FULL_WASM     = File.join(REPO, "build/lilac-full.wasm")
  COMPILED_WASM = File.join(REPO, "build/lilac-compiled.wasm")
  FIXTURE       = File.join(REPO, "test/parity-fixtures/counter")
  BUNDLE_CONFIG = "Lilac::CLI.configure { |c| c.delivery = :bundle }\n"

  def setup
    skip "MRUBY_WASM_RUNTIME_PATH unset" unless ENV["MRUBY_WASM_RUNTIME_PATH"]
    skip "lilac-full.wasm not built (run `make lilac-full`)" unless File.file?(FULL_WASM)
    skip "lilac-compiled.wasm not built (run `make lilac-compiled`)" unless File.file?(COMPILED_WASM)
    skip "dommy-js-quickjs engine required" if ENV["LILAC_JS_ENGINE"] == "dommy-stub"
  end

  def test_full_bundle_boots_injects_mounts_and_reacts
    dist = RuntimeBuildHelper.build_fixture(FIXTURE, "full", config: BUNDLE_CONFIG)
    vm = MrubyWasm.new(wasm_path: FULL_WASM)

    boot_bundle(vm, dist)
    bundle_html = File.read(File.join(dist, "lilac.bundle.html"))
    RuntimeBuildHelper.ruby_scripts(bundle_html).each { |src| vm.eval(src) }
    vm.drain_async!

    assert_mounted(vm)
    click(vm, "inc")
    assert_equal "1", ref_text(vm, "value"), "reactivity through bundle-bound directive"
  end

  def test_compiled_bundle_boots_injects_mounts_and_reacts
    dist = RuntimeBuildHelper.build_fixture(FIXTURE, "compiled", config: BUNDLE_CONFIG)
    vm = MrubyWasm.new(wasm_path: COMPILED_WASM)

    boot_bundle(vm, dist)
    mrbs = RuntimeBuildHelper.mrb_chain(dist)
    assert_operator mrbs.size, :>=, 1, "compiled bundle should emit >= 1 .mrb"
    mrbs.each { |path| vm.load_bytecode(File.binread(path)) }
    vm.drain_async!

    assert_mounted(vm)
    click(vm, "inc")
    assert_equal "1", ref_text(vm, "value")
  end

  private

  # Seed the page body and inject the bundle's <template>s into the live doc,
  # mirroring the boot helper's fetch → DOMParser → appendChild sequence.
  def boot_bundle(vm, dist)
    doc = vm.document
    page = RuntimeBuildHelper.read_dist_page(dist)
    doc.body.inner_html = RuntimeBuildHelper.body_seed(page)

    bundle_html = File.read(File.join(dist, "lilac.bundle.html"))
    holder = doc.create_element("div")
    holder.inner_html = bundle_html
    holder.query_selector_all("template").each { |tpl| doc.body.append_child(tpl) }
  end

  def assert_mounted(vm)
    doc = vm.document
    use = doc.query_selector('[data-use="counter"]')
    refute_nil use, "data-use element present"
    refute_nil use.get_attribute("data-component-id"), "data-use mounted (has data-component-id)"
    assert_nil doc.query_selector('[data-component="counter"]'),
               "no live [data-component] wrapper (children hoisted into data-use)"
    assert_equal "0", ref_text(vm, "value"), "bundle template rendered signal @count=0"
  end

  def click(vm, ref)
    vm.document.query_selector(%([data-ref="#{ref}"])).click
    vm.drain_async!
  end

  def ref_text(vm, ref)
    vm.document.query_selector(%([data-ref="#{ref}"])).text_content.strip
  end
end
