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

  def build!
    Lilac::CLI::Builder.new(
      components_dir: @components,
      pages_dir: @pages,
      output_dir: @output,
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
end
