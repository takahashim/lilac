# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

class TestBuilder < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("lilac-cli-test")
    @components = File.join(@tmp, "components")
    @pages = File.join(@tmp, "pages")
    @output = File.join(@tmp, "dist")
    FileUtils.mkdir_p(@components)
    FileUtils.mkdir_p(@pages)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_widget(name, source)
    File.write(File.join(@components, "#{name}.lil"), source)
  end

  def write_page(name, source)
    File.write(File.join(@pages, "#{name}.html"), source)
  end

  def build!(codegen: :auto, target: :full, mrbc_path: nil,
             lilac_compiled_path: nil, mruby_wasm_js_path: nil,
             packages: [],
             project_root: Dir.pwd,
             delivery: :inline)
    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      codegen: codegen,
      target: target,
      mrbc_path: mrbc_path,
      lilac_compiled_path: lilac_compiled_path,
      mruby_wasm_js_path: mruby_wasm_js_path,
      packages: packages,
      project_root: project_root,
      delivery: delivery,
    ).build
  end

  def read_output(name)
    File.read(File.join(@output, name))
  end

  def test_self_closing_widget_placeholder_is_replaced
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <div data-use="counter"></div>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<div data-component="counter">'
    refute_includes out, "<lilac-component"
  end

  def test_single_quoted_widget_placeholder_is_replaced
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <div data-use="counter"></div>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<div data-component="counter">'
    refute_includes out, "<lilac-component"
  end

  def test_extra_attributes_on_widget_placeholder_are_not_matched
    # By design: extra attributes would silently disappear (the placeholder
    # is replaced wholesale), so we leave the tag untouched. This shows
    # up clearly in the output and lets the user notice the typo.
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <lilac-component name="counter" data-id="3"></lilac-component>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    # Tag stays literal — Counter component markup is NOT injected.
    assert_includes out, '<lilac-component name="counter" data-id="3">'
    refute_includes out, '<div data-component="counter">'
  end

  def test_widget_placeholder_is_replaced_with_default_template
    write_widget "counter", <<~GNT
      <template>
        <div data-component="counter"><span data-ref="count">0</span></div>
      </template>

      <script type="text/ruby">
        class Counter < Lilac::Component; end
      </script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <main>
          <div data-use="counter"></div>
        </main>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<div data-component="counter">'
    refute_includes out, "<lilac-component"
  end

  def test_named_subtemplates_are_emitted_before_body_close
    write_widget "todo-list", <<~GNT
      <template>
        <div data-component="todo-list"><ul data-ref="list"></ul></div>
      </template>

      <template data-template="todo-row">
        <li><span data-ref="title"></span></li>
      </template>

      <script type="text/ruby">
        class TodoList < Lilac::Component; end
      </script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <div data-use="todo-list"></div>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<template data-template="todo-row">'
    # Named template must appear before </body>, after the main markup.
    main_idx = out.index('data-component="todo-list"')
    tmpl_idx = out.index('data-template="todo-row"')
    body_idx = out.index("</body>")
    assert main_idx < tmpl_idx
    assert tmpl_idx < body_idx
  end

  def test_ruby_scripts_are_bundled_into_one_block
    write_widget "a", <<~GNT
      <template><div data-component="a"></div></template>
      <script type="text/ruby">class A < Lilac::Component; end</script>
    GNT

    write_widget "b", <<~GNT
      <template><div data-component="b"></div></template>
      <script type="text/ruby">class B < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <div data-use="a"></div>
        <div data-use="b"></div>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    # Exactly one bundled ruby script block.
    ruby_blocks = out.scan(/<script\s+type="text\/ruby">/)
    assert_equal 1, ruby_blocks.length
    assert_includes out, "class A < Lilac::Component"
    assert_includes out, "class B < Lilac::Component"
  end

  def test_repeated_component_emits_one_template_definition_and_one_script
    write_widget "counter", <<~GNT
      <template><div data-component="counter">0</div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <div data-use="counter"></div>
        <div data-use="counter"></div>
        <div data-use="counter"></div>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    # 3 use sites + 1 definition (inside the injected <template>) for the
    # data-component string. Runtime expands the empty data-use= elements
    # from the definition at mount time.
    assert_equal 3, out.scan('data-use="counter"').length
    assert_equal 1, out.scan('data-component="counter"').length
    assert_equal 1, out.scan("class Counter < Lilac::Component").length
  end

  def test_delivery_bundle_emits_separate_bundle_file
    write_widget "counter", <<~GNT
      <template><div data-component="counter"><span data-text="@count">0</span></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <!DOCTYPE html>
      <html><head><title>t</title></head><body>
        <div data-use="counter"></div>
      </body></html>
    HTML

    build!(delivery: :bundle)

    # Page HTML carries only the <link>, not the template/script.
    out = read_output("index.html")
    assert_includes out, '<link rel="lilac-bundle" href="/lilac.bundle.html">'
    refute_includes out, '<template>'
    refute_includes out, '<script type="text/ruby">'

    # Bundle file contains template + script.
    bundle = File.read(File.join(@output, "lilac.bundle.html"))
    assert_includes bundle, '<template>'
    assert_includes bundle, 'data-component="counter"'
    assert_includes bundle, 'class Counter < Lilac::Component'
  end

  def test_delivery_bundle_compiled_emits_mrb_and_boot_module
    mrbc = mrbc_or_skip
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <!DOCTYPE html>
      <html><head><title>t</title></head><body>
        <div data-use="counter"></div>
      </body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc, delivery: :bundle)

    # bundle.html should carry templates ONLY (no <script>, since compiled
    # has no parser).
    bundle = File.read(File.join(@output, "lilac.bundle.html"))
    assert_includes bundle, '<template>'
    assert_includes bundle, 'data-component="counter"'
    refute_includes bundle, '<script type="text/ruby">'

    # Two .mrb files: one with the bundle scripts (no Lilac.start) and
    # a standalone `Lilac.start` chained after when no page-inline
    # scripts are present.
    mrb_files = Dir.glob(File.join(@output, "*.mrb"))
    assert_equal 2, mrb_files.length

    out = read_output("index.html")
    assert_includes out, '<link rel="lilac-bundle"'
    assert_includes out, 'data-lilac-bootstrap'
    assert_includes out, "loadBytecode"
    assert_includes out, File.basename(mrb_files.first)
  end

  def test_delivery_bundle_link_is_injected_into_head_when_present
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    # Page has <head> — link should go inside </head>
    write_page "index", <<~HTML
      <!DOCTYPE html>
      <html><head><title>t</title></head><body>
        <div data-use="counter"></div>
      </body></html>
    HTML

    build!(delivery: :bundle)
    out = read_output("index.html")
    head_section = out[/<head>.*<\/head>/m]
    assert_includes head_section.to_s, 'rel="lilac-bundle"'
  end

  def test_only_referenced_widgets_are_bundled
    write_widget "used", <<~GNT
      <template><div data-component="used"></div></template>
      <script type="text/ruby">class Used < Lilac::Component; end</script>
    GNT

    write_widget "unused", <<~GNT
      <template><div data-component="unused"></div></template>
      <script type="text/ruby">class Unused < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><div data-use="used"></div></body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, "class Used"
    refute_includes out, "class Unused"
  end

  def test_unknown_component_reference_raises
    write_page "index", <<~HTML
      <html><body><div data-use="nope"></div></body></html>
    HTML

    err = assert_raises(Lilac::CLI::Builder::Error) { build! }
    assert_match(/Unknown component referenced by data-use="nope"/, err.message)
  end

  def test_namespaced_component_name_via_double_dash
    write_widget "admin--user-card", <<~GNT
      <template>
        <div data-component="admin--user-card"></div>
      </template>
      <script type="text/ruby">
        module Admin; class UserCard < Lilac::Component; end; end
      </script>
    GNT

    write_page "index", <<~HTML
      <html><body><div data-use="admin--user-card"></div></body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, 'data-component="admin--user-card"'
    assert_includes out, "module Admin"
  end

  def test_live_reload_option_injects_eventsource_script
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      live_reload: true,
    ).build

    out = read_output("index.html")
    # SSE endpoint + reload trigger
    assert_includes out, "/__lilac/livereload"
    assert_includes out, "location.reload()"
    # Error overlay path: must register an `error` event listener and
    # render `__lilac_err_overlay` when a build-failure SSE arrives.
    assert_match(/addEventListener\(["']error["']/, out)
    assert_includes out, "__lilac_err_overlay"
  end

  def test_live_reload_default_off
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    build!  # live_reload defaults to false
    refute_includes read_output("index.html"), "/__lilac/livereload"
  end

  def test_no_pages_raises
    err = assert_raises(Lilac::CLI::Builder::Error) { build! }
    assert_match(/No pages found/, err.message)
  end

  def test_public_files_are_mirrored_to_output
    write_widget "x", <<~GNT
      <template><div data-component="x"></div></template>
      <script type="text/ruby">class X < Lilac::Component; end</script>
    GNT
    write_page "index", '<html><body><div data-use="x"></div></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "mruby-wasm-js"))
    File.write(File.join(public_dir, "favicon.ico"), "FAVICON_BYTES")
    File.write(File.join(public_dir, "vendor", "lib.js"), "console.log(1)")
    File.write(File.join(public_dir, "vendor", "mruby-wasm-js", "index.js"), "export {}")

    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
    ).build

    assert_equal "FAVICON_BYTES", File.read(File.join(@output, "favicon.ico"))
    assert_equal "console.log(1)", File.read(File.join(@output, "vendor", "lib.js"))
    assert_equal "export {}", File.read(File.join(@output, "vendor", "mruby-wasm-js", "index.js"))
  end

  def test_public_dir_absent_is_silent
    write_widget "x", <<~GNT
      <template><div data-component="x"></div></template>
      <script type="text/ruby">class X < Lilac::Component; end</script>
    GNT
    write_page "index", '<html><body><div data-use="x"></div></body></html>'

    result = Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: File.join(@tmp, "public-not-here"),
    ).build

    assert_equal 0, result[:public_files]
    refute File.exist?(File.join(@output, "vendor"))
  end

  def test_public_dir_skip_gitkeep
    write_widget "x", <<~GNT
      <template><div data-component="x"></div></template>
      <script type="text/ruby">class X < Lilac::Component; end</script>
    GNT
    write_page "index", '<html><body><div data-use="x"></div></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(public_dir)
    File.write(File.join(public_dir, ".gitkeep"), "")
    File.write(File.join(public_dir, "real.css"), "body{}")

    result = Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
    ).build

    assert_equal 1, result[:public_files]
    refute File.exist?(File.join(@output, ".gitkeep"))
    assert File.exist?(File.join(@output, "real.css"))
  end

  def test_public_dir_skips_inactive_target_vendor_for_full
    write_widget "x", <<~GNT
      <template><div data-component="x"></div></template>
      <script type="text/ruby">class X < Lilac::Component; end</script>
    GNT
    write_page "index", '<html><body><div data-use="x"></div></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "lilac-full"))
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "lilac-compiled"))
    File.write(File.join(public_dir, "vendor", "lilac-full", "lilac-full.wasm"), "FULL_BYTES")
    File.write(File.join(public_dir, "vendor", "lilac-compiled", "index.js"), "COMPILED_BOOT")

    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
      target: :full,
    ).build

    assert File.exist?(File.join(@output, "vendor", "lilac-full", "lilac-full.wasm")),
           "full target must ship its own vendor subdir"
    refute File.exist?(File.join(@output, "vendor", "lilac-compiled", "index.js")),
           "full target must NOT ship the compiled vendor subdir"
  end

  def test_public_dir_skips_inactive_target_vendor_for_compiled
    mrbc_or_skip
    # Page with no <lilac-component> placeholder so the compiled target
    # doesn't try to invoke mrbc — this test is about public-mirror
    # exclusion only.
    write_page "static", "<html><body><h1>plain page</h1></body></html>"

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "lilac-full"))
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "lilac-compiled"))
    File.write(File.join(public_dir, "vendor", "lilac-full", "lilac-full.wasm"), "FULL_BYTES")
    File.write(File.join(public_dir, "vendor", "lilac-compiled", "index.js"), "COMPILED_BOOT")

    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
      target: :compiled,
    ).build

    assert File.exist?(File.join(@output, "vendor", "lilac-compiled", "index.js")),
           "compiled target must ship its own vendor subdir"
    refute File.exist?(File.join(@output, "vendor", "lilac-full", "lilac-full.wasm")),
           "compiled target must NOT ship the full vendor subdir"
  end

  def test_public_dir_excluded_dir_prefix_does_not_overmatch
    # `vendor/lilac-full` must not skip `vendor/lilac-full-x` — the
    # exclusion is path-prefix + boundary, not substring.
    write_page "static", "<html><body></body></html>"

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "lilac-full-x"))
    File.write(File.join(public_dir, "vendor", "lilac-full-x", "keep.js"), "KEEP")

    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
      target: :compiled,
    ).build

    assert File.exist?(File.join(@output, "vendor", "lilac-full-x", "keep.js"))
  end

  def test_build_result_reports_public_files_count
    write_widget "x", <<~GNT
      <template><div data-component="x"></div></template>
      <script type="text/ruby">class X < Lilac::Component; end</script>
    GNT
    write_page "index", '<html><body><div data-use="x"></div></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(public_dir)
    File.write(File.join(public_dir, "a.txt"), "a")
    File.write(File.join(public_dir, "b.txt"), "b")

    result = Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
    ).build

    assert_equal 2, result[:public_files]
  end

  # ---- codegen flag --------------------------------------------------

  def test_codegen_auto_emits_bind_template_hook
    write_widget "counter", <<~GNT
      <template>
        <div data-component="counter">
          <span data-text="@count">0</span>
        </div>
      </template>
      <script type="text/ruby">
        class Counter < Lilac::Component
          def setup; @count = signal(0); end
        end
      </script>
    GNT
    write_page "index", '<html><body><div data-use="counter"></div></body></html>'

    build!(codegen: :auto)
    out = read_output("index.html")
    assert_includes out, "bind_template_hook",
                    "codegen :auto should emit the bind_template_hook override"
    assert_includes out, "module Counter",
                    "codegen :auto should declare the Lilac::Bindings::Counter module"
  end

  def test_codegen_off_skips_bind_template_hook
    write_widget "counter", <<~GNT
      <template>
        <div data-component="counter">
          <span data-text="@count">0</span>
        </div>
      </template>
      <script type="text/ruby">
        class Counter < Lilac::Component
          def setup; @count = signal(0); end
        end
      </script>
    GNT
    write_page "index", '<html><body><div data-use="counter"></div></body></html>'

    build!(codegen: :off)
    out = read_output("index.html")
    refute_includes out, "bind_template_hook",
                    "codegen :off must not emit bind_template_hook; runtime takes over"
    refute_includes out, "Lilac::Bindings::Counter"
    # The declarative directive itself stays in the HTML so the runtime
    # scanner can find and wire it at mount time.
    assert_includes out, 'data-text="@count"'
  end

  # ---- target: :compiled ------------------------------------------

  def test_target_compiled_emits_mrb_and_boot_module
    mrbc = mrbc_or_skip
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">
        class Counter < Lilac::Component
          def setup; @count = signal(0); end
        end
      </script>
    GNT
    write_page "index", '<html><body><div data-use="counter"></div></body></html>'

    build!(target: :compiled, mrbc_path: mrbc)

    out = read_output("index.html")
    # Inline Ruby script tag is replaced with a module-script boot loader.
    refute_includes out, '<script type="text/ruby">',
                    "compiled target must not leave inline Ruby in dist HTML"
    assert_includes out, "data-lilac-bootstrap"
    # Inline boot module imports the bridge directly (no dependency on
    # the npm package's boot helper — see render_compiled_boot_module).
    assert_includes out, 'import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js"'
    assert_includes out, 'vm.loadBytecode(new Uint8Array(await (await fetch'
    # The fetch URL must reference a content-hashed .mrb sibling.
    assert_match(/fetch\("\.\/app\.[0-9a-f]{8}\.mrb"\)/, out)

    # The .mrb itself was produced under output_dir with RITE magic.
    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length,
                 "expected exactly one .mrb under output_dir, found #{mrb_files.inspect}"
    bytes = File.binread(mrb_files.first)
    assert_equal "RITE", bytes[0, 4]
  end

  def test_target_compiled_with_packages_loads_them_before_user_bytecode
    mrbc = mrbc_or_skip
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    # Sandbox a fake package bytecode file. The bytes are arbitrary —
    # the builder doesn't validate them; runtime would, but for the
    # build-time injection we just need a path that exists.
    pkg_src = File.join(Dir.mktmpdir("lilac-package-fixture"), "extras.mrb")
    File.binwrite(pkg_src, "RITE0400\x00" * 8)

    build!(target: :compiled, mrbc_path: mrbc, packages: [pkg_src])

    # The package .mrb was copied into dist/packages/.
    staged = File.join(@output, "packages", "extras.mrb")
    assert File.file?(staged), "expected package staged at #{staged}"

    # The boot script fetches the package BEFORE the user bytecode so
    # `register_directive` / class definitions are ready before component
    # mount.
    out = read_output("index.html")
    pkg_pos  = out.index('fetch("./packages/extras.mrb")')
    user_pos = out =~ /fetch\("\.\/app\.[0-9a-f]{8}\.mrb"\)/
    refute_nil pkg_pos,  "boot script must reference the staged package"
    refute_nil user_pos, "boot script must still load the user bytecode"
    assert pkg_pos < user_pos,
           "package must be fetched before the user bytecode"
  end

  def test_target_compiled_compiles_and_stages_discovered_package_gems
    mrbc = mrbc_or_skip
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    # Fake a gem-discovered package by stubbing `PackageDiscovery.run`.
    # The mrblib content is real Ruby (so mrbc accepts it). The Builder
    # auto-stages it under the gem name + injects loadBytecode before
    # the user bytecode.
    pkg_dir = Dir.mktmpdir("lilac-discovered-package-")
    File.write(File.join(pkg_dir, "fake.rb"), "X = 1")
    discovered = Lilac::CLI::PackageDiscovery::Discovered.new(
      name: "lilac-fake",
      version: "0.0.1",
      mrblib_files: [File.join(pkg_dir, "fake.rb")],
    )

    stub_discovery([discovered]) do
      build!(target: :compiled, mrbc_path: mrbc)
    end

    staged = File.join(@output, "packages", "lilac-fake.mrb")
    assert File.file?(staged), "expected gem package staged at #{staged}"
    assert_equal "RITE", File.binread(staged)[0, 4], "compiled bytecode has RITE magic"

    out = read_output("index.html")
    pkg_pos  = out.index('fetch("./packages/lilac-fake.mrb")')
    user_pos = out =~ /fetch\("\.\/app\.[0-9a-f]{8}\.mrb"\)/
    refute_nil pkg_pos, "boot script must reference the staged gem package"
    refute_nil user_pos
    assert pkg_pos < user_pos
  end

  def stub_discovery(list)
    saved = Lilac::CLI::PackageDiscovery.method(:run)
    Lilac::CLI::PackageDiscovery.define_singleton_method(:run) { list }
    yield
  ensure
    Lilac::CLI::PackageDiscovery.define_singleton_method(:run, &saved)
  end

  def test_target_compiled_raises_when_package_path_missing
    mrbc = mrbc_or_skip
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    bogus = File.join(Dir.mktmpdir("lilac-package-missing"), "nope.mrb")
    err = assert_raises(Lilac::CLI::Builder::Error) do
      build!(target: :compiled, mrbc_path: mrbc, packages: [bogus])
    end
    assert_includes err.message, "Lilac package `.mrb` not found"
  end

  def test_target_full_stages_packages_and_writes_manifest
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    pkg_src = File.join(Dir.mktmpdir("lilac-package-fixture-full"), "extras.mrb")
    File.binwrite(pkg_src, "RITE0400\x00" * 8)

    # `:full` builds don't generate their own boot module — the user
    # owns the `<script type="module">` in their page template. lilac-cli
    # surfaces packages to that script via a `lilac.packages.json`
    # manifest the boot can `fetch`. (decisions §25/§26)
    build!(target: :full, packages: [pkg_src])

    staged = File.join(@output, "packages", "extras.mrb")
    assert File.file?(staged), "expected package staged at #{staged}"

    manifest_path = File.join(@output, "lilac.packages.json")
    assert File.file?(manifest_path), "expected lilac.packages.json manifest"
    manifest = JSON.parse(File.read(manifest_path))
    assert_equal ["./packages/extras.mrb"], manifest["packages"]
  end

  def test_target_full_omits_packages_manifest_when_none_present
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body><div data-use="counter"></div></body></html>
    HTML

    build!(target: :full)

    refute File.exist?(File.join(@output, "lilac.packages.json")),
           "manifest must not be written when there are no packages (boot script falls back gracefully on 404)"
  end

  def test_target_compiled_omits_mrb_when_no_components_used
    mrbc = mrbc_or_skip
    write_page "static", "<html><body><h1>plain page</h1></body></html>"

    build!(target: :compiled, mrbc_path: mrbc)

    # No <lilac-component> tag, so no scripts collected → no .mrb emit
    # and no boot module injection.
    assert_empty Dir.glob(File.join(@output, "*.mrb"))
    out = read_output("static.html")
    refute_includes out, "data-lilac-bootstrap"
    refute_includes out, "lilac-compiled"
  end

  # ---- page-inline `<script type="text/ruby">` handling ------------

  def test_target_compiled_includes_page_inline_ruby_in_mrb
    mrbc = mrbc_or_skip
    write_page "index", <<~HTML
      <html><body>
      <script type="text/ruby">
      class PageOnlyFoo
        def hello; end
      end
      </script>
      </body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc)
    out = read_output("index.html")

    # The `<script type="text/ruby">` tag stays in the dist HTML even
    # for compiled mode: the browser ignores `text/ruby`, the compiled
    # wasm has no parser to execute it, so the tag is dead text — but
    # keeping it makes "view source" / source-mirror features work and
    # preserves symmetry with target=full.
    assert_includes out, '<script type="text/ruby">'
    assert_includes out, "class PageOnlyFoo"
    assert_includes out, "data-lilac-bootstrap"

    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length
    # Class names land in the mruby symbol table verbatim — searchable
    # without parsing the mrb format.
    assert_includes File.binread(mrb_files.first), "PageOnlyFoo"
  end

  def test_target_full_preserves_page_inline_ruby
    write_page "index", <<~HTML
      <html><body>
      <script type="text/ruby">
      class PageOnlyBar; end
      </script>
      </body></html>
    HTML

    build!(target: :full)
    out = read_output("index.html")

    assert_includes out, '<script type="text/ruby">'
    assert_includes out, "class PageOnlyBar"
  end

  def test_target_compiled_dedupes_identical_inline_across_pages
    mrbc = mrbc_or_skip
    shared = <<~HTML
      <html><body>
      <script type="text/ruby">
      class SharedKlass; end
      </script>
      </body></html>
    HTML
    write_page "page_a", shared
    write_page "page_b", shared

    build!(target: :compiled, mrbc_path: mrbc)

    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length,
                 "identical inline source on two pages must dedupe via content-hash"
  end

  def test_target_compiled_per_page_mrb_when_inline_differs
    mrbc = mrbc_or_skip
    write_page "page_a", <<~HTML
      <html><body><script type="text/ruby">class KlassA; end</script></body></html>
    HTML
    write_page "page_b", <<~HTML
      <html><body><script type="text/ruby">class KlassB; end</script></body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc)

    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 2, mrb_files.length,
                 "different inline source per page must produce per-page .mrb"
  end

  # ---- compiled auto-vendor ---------------------------------------

  def test_target_compiled_auto_vendors_runtime
    mrbc = mrbc_or_skip
    fixture = scaffold_compiled_runtime_fixture
    write_page "index", <<~HTML
      <html><body><script type="text/ruby">class Vendored; end</script></body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc,
           lilac_compiled_path: fixture[:wasm],
           mruby_wasm_js_path: fixture[:bridge])

    # wasm + bridge are vendored. The boot module is rendered inline
    # into the HTML by render_compiled_boot_module, so no vendored
    # index.js file is needed.
    assert File.exist?(File.join(@output, "vendor", "lilac-compiled", "lilac.wasm"))
    assert File.exist?(File.join(@output, "vendor", "lilac-compiled", "mruby-wasm-js", "index.js"))
    refute File.exist?(File.join(@output, "vendor", "lilac-compiled", "index.js"))
  end

  def test_target_compiled_emits_inline_boot_using_bridge_directly
    mrbc = mrbc_or_skip
    fixture = scaffold_compiled_runtime_fixture
    write_page "index", <<~HTML
      <html><body><script type="text/ruby">class Vendored; end</script></body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc,
           lilac_compiled_path: fixture[:wasm],
           mruby_wasm_js_path: fixture[:bridge])

    out = read_output("index.html")
    # The boot module talks to the bridge directly (no dependency on
    # the npm package's `index.js` boot helper).
    assert_includes out, 'import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js"'
    assert_includes out, 'vm.loadBytecode(new Uint8Array(await (await fetch'
    refute_includes out, 'vendor/lilac-compiled/index.js',
                    "compiled boot must not import the npm helper's index.js"
    refute_includes out, "loadIrep",
                    "compiled boot must use the current bridge API name"
  end

  def test_target_compiled_raises_when_runtime_not_resolved
    mrbc = mrbc_or_skip
    # Sandbox project_root + override the gem's monorepo discovery so
    # nothing resolves: no explicit path, no env var, no node_modules,
    # no monorepo.
    sandbox = Dir.mktmpdir("lilac-no-rt-")
    no_repo = File.join(sandbox, "nope")
    saved_lilac_compiled_wasm = ENV["LILAC_COMPILED_WASM"]
    saved_mruby_wasm_js_path = ENV["MRUBY_WASM_JS_PATH"]
    begin
      write_page "index", <<~HTML
        <html><body><script type="text/ruby">class X; end</script></body></html>
      HTML

      ENV.delete("LILAC_COMPILED_WASM")
      ENV.delete("MRUBY_WASM_JS_PATH")

      # The Builder constructs the resolver itself; to make the resolver
      # forget the real monorepo we point it at an empty sandbox via the
      # build helper's pass-through.
      err = assert_raises(Lilac::CLI::CompiledRuntimeResolver::Error) do
        Lilac::CLI::Builder.new(
          components_dir: @components,
          pages_dir: @pages,
          output_dir: @output,
          target: :compiled,
          mrbc_path: mrbc,
          project_root: sandbox,
        ).tap do |b|
          # Inject a resolver whose monorepo_root points at /nope so the
          # discovery genuinely fails — needed because the real monorepo
          # ancestor of __FILE__ has the runtime artefacts present.
          # `disable_gem_discovery: true` also blocks the `lilac-wasm-bin`
          # gem fallback (which would otherwise land back in the real
          # monorepo's build/).
          stub = Lilac::CLI::CompiledRuntimeResolver.new(
            project_root: sandbox, monorepo_root: no_repo,
            disable_gem_discovery: true,
          )
          b.instance_variable_set(:@compiled_runtime_resolver, stub)
        end.build
      end
      assert_match(/lilac-compiled\.wasm not found/, err.message)
    ensure
      ENV["LILAC_COMPILED_WASM"] = saved_lilac_compiled_wasm
      ENV["MRUBY_WASM_JS_PATH"] = saved_mruby_wasm_js_path
      FileUtils.remove_entry(sandbox)
    end
  end

  def test_target_full_does_not_auto_vendor
    write_page "index", "<html><body><h1>hi</h1></body></html>"

    build!(target: :full)
    refute File.exist?(File.join(@output, "vendor", "lilac-compiled")),
           "full target must not emit a compiled-runtime vendor tree"
  end

  def test_target_compiled_combines_component_and_page_inline
    # Component script + page-inline script both end up in the same .mrb.
    mrbc = mrbc_or_skip
    write_widget "x", <<~GNT
      <template><div data-component="x"></div></template>
      <script type="text/ruby">class WidgetX < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body>
      <div data-use="x"></div>
      <script type="text/ruby">class PageY; end</script>
      </body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc)

    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length
    bytes = File.binread(mrb_files.first)
    assert_includes bytes, "WidgetX"
    assert_includes bytes, "PageY"
  end

  # ---- §B Lilac.start lives in the boot helper layer -----------

  def test_target_full_does_not_inject_lilac_start_into_script_block
    write_page "index", <<~HTML
      <html><body>
      <script type="text/ruby">
      class PageOnlyBar; end
      </script>
      </body></html>
    HTML

    build!(target: :full)
    out = read_output("index.html")

    # User's page-inline script is preserved, but the builder does NOT
    # inject `Lilac.start` — boot is the boot helper layer's
    # responsibility (decisions §20.6). The Lilac-specific boot helper
    # (e.g. `boot.js` shipped under `public/`) calls it after evaluating
    # every `<script type="text/ruby">`.
    assert_includes out, "class PageOnlyBar"
    refute_includes out, "Lilac.start"
  end

  def test_target_full_pure_static_page_emits_no_script_block
    write_page "index", "<html><body><h1>static</h1></body></html>"
    build!(target: :full)
    out = read_output("index.html")
    # No user Ruby on the page → no injected `<script type="text/ruby">`
    # at all, and no Lilac.start anywhere (the boot helper still loads
    # but has nothing to mount, which is fine — Registry#start is
    # idempotent and a no-op subtree mount is harmless).
    refute_includes out, "Lilac.start"
    refute_match(/<script type="text\/ruby"/, out)
  end

  def test_target_compiled_bundle_includes_lilac_start_in_bytecode
    mrbc = mrbc_or_skip
    write_page "index", <<~HTML
      <html><body><script type="text/ruby">class Boot1; end</script></body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc)
    out = read_output("index.html")

    # The compiled wasm has no parser, so `Lilac.start` must travel in
    # the bytecode and run as part of `loadBytecode` (decisions §20.6
    # caveat). The inline boot module deliberately does NOT call
    # `vm.eval("Lilac.start")`.
    refute_match(/vm\.eval\(/, out,
                 "inline compiled boot module must not vm.eval anything (no parser in compiled wasm)")

    # The .mrb bundle carries the Lilac/start sym pair appended at the
    # tail of the bundle by the builder.
    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length
    bytes = File.binread(mrb_files.first)
    assert_includes bytes, "Lilac",
                    "compiled bundle must include Lilac.start (Lilac sym missing)"
    assert_includes bytes, "start",
                    "compiled bundle must include Lilac.start (start sym missing)"
  end

  # ---- §A scope guard --------------------------------------------

  def test_lil_and_page_inline_same_name_raises
    write_widget "counter", <<~GNT
      <template><div data-component="counter">x</div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    write_page "index", <<~HTML
      <html><body>
      <div data-component="counter"><span>y</span></div>
      </body></html>
    HTML

    err = assert_raises(Lilac::CLI::Builder::Error) { build!(target: :full) }
    assert_match(/Duplicate component definition "counter".+conflicts with components\/counter\.lil/, err.message)
  end

  def test_same_page_duplicate_page_inline_data_component_raises
    write_page "index", <<~HTML
      <html><body>
      <div data-component="row">A</div>
      <div data-component="row">B</div>
      </body></html>
    HTML

    err = assert_raises(Lilac::CLI::Builder::Error) { build!(target: :full) }
    assert_match(/Duplicate component definition "row".+also declared at line/, err.message)
  end

  def test_cross_page_divergent_page_inline_warns
    write_page "a", <<~HTML
      <html><body>
      <div data-component="shared"><span>shape-A</span></div>
      </body></html>
    HTML
    write_page "b", <<~HTML
      <html><body>
      <div data-component="shared"><span>SHAPE-B-different</span></div>
      </body></html>
    HTML

    captured = capture_io { build!(target: :full) }
    combined = captured.join
    assert_match(/page-inline component "shared".+different shapes/, combined)
  end

  def test_cross_page_identical_page_inline_does_not_warn
    same = <<~HTML
      <html><body>
      <div data-component="card"><span>same</span></div>
      </body></html>
    HTML
    write_page "a", same
    write_page "b", same

    captured = capture_io { build!(target: :full) }
    refute_match(/different shapes/, captured.join)
  end

  def test_page_inline_class_name_collision_with_lil_raises
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT
    # Note: does NOT use data-component="counter" (so R1 doesn't fire),
    # but redefines the Counter class in page-inline. R4 catches this.
    write_page "index", <<~HTML
      <html><body>
      <script type="text/ruby">
      class Counter; end
      </script>
      </body></html>
    HTML

    err = assert_raises(Lilac::CLI::Builder::Error) { build!(target: :full) }
    assert_match(/page-inline class Counter.+collides/, err.message)
  end

  private

  # Dummy lilac-compiled runtime sources to exercise the auto-vendor
  # path without depending on the monorepo's real wasm build.
  def scaffold_compiled_runtime_fixture
    fixture_root = File.join(@tmp, "runtime-fixture")
    pkg = File.join(fixture_root, "lilac-compiled")
    bridge = File.join(fixture_root, "mruby-wasm-js")
    FileUtils.mkdir_p(pkg)
    FileUtils.mkdir_p(bridge)
    wasm = File.join(pkg, "lilac.wasm")
    File.binwrite(wasm, "FAKE_WASM_BYTES")
    File.write(File.join(bridge, "index.js"), "// bridge stub\n")
    File.write(File.join(bridge, "wasi-preview1.js"), "// wasi stub\n")
    { wasm: wasm, bridge: bridge }
  end

  def mrbc_or_skip
    return ENV["MRBC"] if ENV["MRBC"] && File.executable?(ENV["MRBC"])
    if (mwr = ENV["MRUBY_WASM_RUNTIME_PATH"])
      candidate = File.join(mwr, "mruby", "build", "host", "bin", "mrbc")
      return candidate if File.executable?(candidate)
    end
    on_path = (ENV["PATH"] || "").split(File::PATH_SEPARATOR).map { |d| File.join(d, "mrbc") }.find do |p|
      File.executable?(p) && !File.directory?(p)
    end
    return on_path if on_path
    skip "mrbc not available; set MRBC or MRUBY_WASM_RUNTIME_PATH to run this test"
  end
end
