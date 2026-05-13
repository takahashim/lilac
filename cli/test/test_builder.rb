# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestBuilder < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("grainet-cli-test")
    @widgets = File.join(@tmp, "widgets")
    @pages = File.join(@tmp, "pages")
    @output = File.join(@tmp, "dist")
    FileUtils.mkdir_p(@widgets)
    FileUtils.mkdir_p(@pages)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_widget(name, source)
    File.write(File.join(@widgets, "#{name}.gnt"), source)
  end

  def write_page(name, source)
    File.write(File.join(@pages, "#{name}.html"), source)
  end

  def build!
    Grainet::CLI::Builder.new(
      widgets_dir: @widgets,
      pages_dir: @pages,
      output_dir: @output,
    ).build
  end

  def read_output(name)
    File.read(File.join(@output, name))
  end

  def test_self_closing_widget_placeholder_is_replaced
    write_widget "counter", <<~GNT
      <template><div data-widget="counter"></div></template>
      <script type="text/ruby">class Counter < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <grainet-widget name="counter" />
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<div data-widget="counter">'
    refute_includes out, "<grainet-widget"
  end

  def test_single_quoted_widget_placeholder_is_replaced
    write_widget "counter", <<~GNT
      <template><div data-widget="counter"></div></template>
      <script type="text/ruby">class Counter < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <grainet-widget name='counter'></grainet-widget>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<div data-widget="counter">'
    refute_includes out, "<grainet-widget"
  end

  def test_extra_attributes_on_widget_placeholder_are_not_matched
    # By design: extra attributes would silently disappear (the placeholder
    # is replaced wholesale), so we leave the tag untouched. This shows
    # up clearly in the output and lets the user notice the typo.
    write_widget "counter", <<~GNT
      <template><div data-widget="counter"></div></template>
      <script type="text/ruby">class Counter < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <grainet-widget name="counter" data-id="3"></grainet-widget>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    # Tag stays literal — Counter component markup is NOT injected.
    assert_includes out, '<grainet-widget name="counter" data-id="3">'
    refute_includes out, '<div data-widget="counter">'
  end

  def test_widget_placeholder_is_replaced_with_default_template
    write_widget "counter", <<~GNT
      <template>
        <div data-widget="counter"><span data-ref="count">0</span></div>
      </template>

      <script type="text/ruby">
        class Counter < Grainet::Widget; end
      </script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <main>
          <grainet-widget name="counter"></grainet-widget>
        </main>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<div data-widget="counter">'
    refute_includes out, "<grainet-widget"
  end

  def test_named_subtemplates_are_emitted_before_body_close
    write_widget "todo-list", <<~GNT
      <template>
        <div data-widget="todo-list"><ul data-ref="list"></ul></div>
      </template>

      <template data-template="todo-row">
        <li><span data-ref="title"></span></li>
      </template>

      <script type="text/ruby">
        class TodoList < Grainet::Widget; end
      </script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <grainet-widget name="todo-list"></grainet-widget>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, '<template data-template="todo-row">'
    # Named template must appear before </body>, after the main markup.
    main_idx = out.index('data-widget="todo-list"')
    tmpl_idx = out.index('data-template="todo-row"')
    body_idx = out.index("</body>")
    assert main_idx < tmpl_idx
    assert tmpl_idx < body_idx
  end

  def test_ruby_scripts_are_bundled_into_one_block
    write_widget "a", <<~GNT
      <template><div data-widget="a"></div></template>
      <script type="text/ruby">class A < Grainet::Widget; end</script>
    GNT

    write_widget "b", <<~GNT
      <template><div data-widget="b"></div></template>
      <script type="text/ruby">class B < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <grainet-widget name="a"></grainet-widget>
        <grainet-widget name="b"></grainet-widget>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    # Exactly one bundled ruby script block.
    ruby_blocks = out.scan(/<script\s+type="text\/ruby">/)
    assert_equal 1, ruby_blocks.length
    assert_includes out, "class A < Grainet::Widget"
    assert_includes out, "class B < Grainet::Widget"
  end

  def test_repeated_component_inlines_template_each_time_but_script_once
    write_widget "counter", <<~GNT
      <template><div data-widget="counter">0</div></template>
      <script type="text/ruby">class Counter < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body>
        <grainet-widget name="counter"></grainet-widget>
        <grainet-widget name="counter"></grainet-widget>
        <grainet-widget name="counter"></grainet-widget>
      </body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_equal 3, out.scan('data-widget="counter"').length
    assert_equal 1, out.scan("class Counter < Grainet::Widget").length
  end

  def test_only_referenced_widgets_are_bundled
    write_widget "used", <<~GNT
      <template><div data-widget="used"></div></template>
      <script type="text/ruby">class Used < Grainet::Widget; end</script>
    GNT

    write_widget "unused", <<~GNT
      <template><div data-widget="unused"></div></template>
      <script type="text/ruby">class Unused < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><grainet-widget name="used"></grainet-widget></body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, "class Used"
    refute_includes out, "class Unused"
  end

  def test_unknown_component_reference_raises
    write_page "index", <<~HTML
      <html><body><grainet-widget name="nope"></grainet-widget></body></html>
    HTML

    err = assert_raises(Grainet::CLI::Builder::Error) { build! }
    assert_match(/Unknown component: "nope"/, err.message)
  end

  def test_namespaced_component_name_via_double_dash
    write_widget "admin--user-card", <<~GNT
      <template>
        <div data-widget="admin--user-card"></div>
      </template>
      <script type="text/ruby">
        module Admin; class UserCard < Grainet::Widget; end; end
      </script>
    GNT

    write_page "index", <<~HTML
      <html><body><grainet-widget name="admin--user-card"></grainet-widget></body></html>
    HTML

    build!
    out = read_output("index.html")
    assert_includes out, 'data-widget="admin--user-card"'
    assert_includes out, "module Admin"
  end

  def test_live_reload_option_injects_eventsource_script
    write_widget "counter", <<~GNT
      <template><div data-widget="counter"></div></template>
      <script type="text/ruby">class Counter < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><grainet-widget name="counter"></grainet-widget></body></html>
    HTML

    Grainet::CLI::Builder.new(
      widgets_dir: @widgets,
      pages_dir: @pages,
      output_dir: @output,
      live_reload: true,
    ).build

    out = read_output("index.html")
    assert_includes out, "/__grainet/livereload"
    assert_includes out, "location.reload()"
  end

  def test_live_reload_default_off
    write_widget "counter", <<~GNT
      <template><div data-widget="counter"></div></template>
      <script type="text/ruby">class Counter < Grainet::Widget; end</script>
    GNT

    write_page "index", <<~HTML
      <html><body><grainet-widget name="counter"></grainet-widget></body></html>
    HTML

    build!  # live_reload defaults to false
    refute_includes read_output("index.html"), "/__grainet/livereload"
  end

  def test_no_pages_raises
    err = assert_raises(Grainet::CLI::Builder::Error) { build! }
    assert_match(/No pages found/, err.message)
  end

  def test_public_files_are_mirrored_to_output
    write_widget "x", <<~GNT
      <template><div data-widget="x"></div></template>
      <script type="text/ruby">class X < Grainet::Widget; end</script>
    GNT
    write_page "index", '<html><body><grainet-widget name="x"></grainet-widget></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(File.join(public_dir, "vendor", "mruby-wasm-js"))
    File.write(File.join(public_dir, "favicon.ico"), "FAVICON_BYTES")
    File.write(File.join(public_dir, "vendor", "lib.js"), "console.log(1)")
    File.write(File.join(public_dir, "vendor", "mruby-wasm-js", "index.js"), "export {}")

    Grainet::CLI::Builder.new(
      widgets_dir: @widgets,
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
      <template><div data-widget="x"></div></template>
      <script type="text/ruby">class X < Grainet::Widget; end</script>
    GNT
    write_page "index", '<html><body><grainet-widget name="x"></grainet-widget></body></html>'

    result = Grainet::CLI::Builder.new(
      widgets_dir: @widgets,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: File.join(@tmp, "public-not-here"),
    ).build

    assert_equal 0, result[:public_files]
    refute File.exist?(File.join(@output, "vendor"))
  end

  def test_public_dir_skip_gitkeep
    write_widget "x", <<~GNT
      <template><div data-widget="x"></div></template>
      <script type="text/ruby">class X < Grainet::Widget; end</script>
    GNT
    write_page "index", '<html><body><grainet-widget name="x"></grainet-widget></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(public_dir)
    File.write(File.join(public_dir, ".gitkeep"), "")
    File.write(File.join(public_dir, "real.css"), "body{}")

    result = Grainet::CLI::Builder.new(
      widgets_dir: @widgets,
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
      <template><div data-widget="x"></div></template>
      <script type="text/ruby">class X < Grainet::Widget; end</script>
    GNT
    write_page "index", '<html><body><grainet-widget name="x"></grainet-widget></body></html>'

    public_dir = File.join(@tmp, "public")
    FileUtils.mkdir_p(public_dir)
    File.write(File.join(public_dir, "a.txt"), "a")
    File.write(File.join(public_dir, "b.txt"), "b")

    result = Grainet::CLI::Builder.new(
      widgets_dir: @widgets,
      pages_dir: @pages,
      output_dir: @output,
      public_dir: public_dir,
    ).build

    assert_equal 2, result[:public_files]
  end
end
