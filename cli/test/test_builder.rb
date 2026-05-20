# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

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
             project_root: Dir.pwd)
    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      codegen: codegen,
      target: target,
      mrbc_path: mrbc_path,
      lilac_compiled_path: lilac_compiled_path,
      mruby_wasm_js_path: mruby_wasm_js_path,
      project_root: project_root,
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
        <lilac-component name="counter" />
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
        <lilac-component name='counter'></lilac-component>
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
          <lilac-component name="counter"></lilac-component>
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
        <lilac-component name="todo-list"></lilac-component>
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
        <lilac-component name="a"></lilac-component>
        <lilac-component name="b"></lilac-component>
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

  def test_repeated_component_inlines_template_each_time_but_script_once
    write_widget "counter", <<~GNT
      <template><div data-component="counter">0</div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <lilac-component name="counter"></lilac-component>
        <lilac-component name="counter"></lilac-component>
        <lilac-component name="counter"></lilac-component>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_equal 3, out.scan('data-component="counter"').length
    assert_equal 1, out.scan("class Counter < Lilac::Component").length
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
      <html><body><lilac-component name="used"></lilac-component></body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, "class Used"
    refute_includes out, "class Unused"
  end

  def test_unknown_component_reference_raises
    write_page "index", <<~HTML
      <html><body><lilac-component name="nope"></lilac-component></body></html>
    HTML

    err = assert_raises(Lilac::CLI::Builder::Error) { build! }
    assert_match(/Unknown component: "nope"/, err.message)
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
      <html><body><lilac-component name="admin--user-card"></lilac-component></body></html>
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
      <html><body><lilac-component name="counter"></lilac-component></body></html>
    HTML

    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
      live_reload: true,
    ).build

    out = read_output("index.html")
    assert_includes out, "/__lilac/livereload"
    assert_includes out, "location.reload()"
  end

  def test_live_reload_default_off
    write_widget "counter", <<~GNT
      <template><div data-component="counter"></div></template>
      <script type="text/ruby">class Counter < Lilac::Component; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><lilac-component name="counter"></lilac-component></body></html>
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
    write_page "index", '<html><body><lilac-component name="x"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="x"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="x"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="x"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="x"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="counter"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="counter"></lilac-component></body></html>'

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
    write_page "index", '<html><body><lilac-component name="counter"></lilac-component></body></html>'

    build!(target: :compiled, mrbc_path: mrbc)

    out = read_output("index.html")
    # Inline Ruby script tag is replaced with a module-script boot loader.
    refute_includes out, '<script type="text/ruby">',
                    "compiled target must not leave inline Ruby in dist HTML"
    assert_includes out, "data-lilac-bootstrap"
    # Inline boot module imports the bridge directly (no dependency on
    # the npm package's boot helper — see render_compiled_boot_module).
    assert_includes out, 'import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js"'
    assert_includes out, 'vm.loadBytecode(bytecode)'
    # The fetch URL must reference a content-hashed .mrb sibling.
    assert_match(/fetch\("\.\/app\.[0-9a-f]{8}\.mrb"\)/, out)

    # The .mrb itself was produced under output_dir with RITE magic.
    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length,
                 "expected exactly one .mrb under output_dir, found #{mrb_files.inspect}"
    bytes = File.binread(mrb_files.first)
    assert_equal "RITE", bytes[0, 4]
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

    refute_includes out, '<script type="text/ruby">',
                    "compiled target must strip page-inline Ruby scripts"
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
    assert_includes out, 'vm.loadBytecode(bytecode)'
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
          stub = Lilac::CLI::CompiledRuntimeResolver.new(
            project_root: sandbox, monorepo_root: no_repo,
          )
          b.instance_variable_set(:@compiled_runtime_resolver, stub)
        end.build
      end
      assert_match(/lilac-compiled\.wasm not found/, err.message)
    ensure
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
      <lilac-component name="x"></lilac-component>
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

  # ---- §B auto Lilac.start --------------------------------------

  def test_target_full_auto_appends_lilac_start
    write_page "index", <<~HTML
      <html><body>
      <script type="text/ruby">
      class PageOnlyBar; end
      </script>
      </body></html>
    HTML

    build!(target: :full)
    out = read_output("index.html")

    # The user's page-inline script is preserved verbatim, and a
    # framework-owned `Lilac.start` is appended in a separate injected
    # block before `</body>` (auto-boot, §B.2).
    assert_includes out, "class PageOnlyBar"
    assert_includes out, "Lilac.start"
    user_pos = out.index("class PageOnlyBar")
    start_pos = out.index("Lilac.start")
    assert start_pos > user_pos,
           "auto-inserted Lilac.start must come after user page-inline scripts in document order"
  end

  def test_target_full_no_lilac_start_when_page_has_no_ruby
    write_page "index", "<html><body><h1>static</h1></body></html>"
    build!(target: :full)
    out = read_output("index.html")
    refute_includes out, "Lilac.start"
  end

  def test_target_compiled_bundle_includes_lilac_start
    mrbc = mrbc_or_skip
    write_page "index", <<~HTML
      <html><body><script type="text/ruby">class Boot1; end</script></body></html>
    HTML

    build!(target: :compiled, mrbc_path: mrbc)
    mrb_files = Dir.glob(File.join(@output, "app.*.mrb"))
    assert_equal 1, mrb_files.length
    bytes = File.binread(mrb_files.first)
    # mrbc stores method calls as separate sym entries ("Lilac" + "start")
    # in the bytecode symbol table — not as the literal source text.
    # Both symbols appearing together is what proves the auto-append
    # made it into the bundle.
    assert_includes bytes, "Lilac",
                    "compiled bundle must auto-append Lilac.start (Lilac sym missing)"
    assert_includes bytes, "start",
                    "compiled bundle must auto-append Lilac.start (start sym missing)"
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
    assert_match(/data-component="counter".+collides with components\/counter\.lil/, err.message)
  end

  def test_same_page_duplicate_page_inline_data_component_raises
    write_page "index", <<~HTML
      <html><body>
      <div data-component="row">A</div>
      <div data-component="row">B</div>
      </body></html>
    HTML

    err = assert_raises(Lilac::CLI::Builder::Error) { build!(target: :full) }
    assert_match(/data-component="row".+is declared twice/, err.message)
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
