# frozen_string_literal: true

require_relative "test_helper"

class TestSFC < Minitest::Test
  def test_single_anonymous_template_and_script
    source = <<~GNT
      <template>
        <span data-ref="count">0</span>
      </template>

      <script type="text/ruby">
        class Counter < Lilac::Component
        end
      </script>
    GNT

    comp = Lilac::CLI::SFC.parse(source)
    assert_equal 1, comp.templates.length
    assert_nil comp.templates.first.name
    assert_includes comp.templates.first.body, 'data-ref="count"'
    assert_includes comp.script, "class Counter < Lilac::Component"
  end

  def test_named_template
    source = <<~GNT
      <template data-template="row">
        <li><span data-ref="label"></span></li>
      </template>

      <script type="text/ruby">
        class TodoList < Lilac::Component
        end
      </script>
    GNT

    comp = Lilac::CLI::SFC.parse(source)
    assert_equal "row", comp.templates.first.name
    assert_equal 0, comp.default_templates.length
    assert_equal 1, comp.named_templates.length
  end

  def test_multiple_templates_in_document_order
    source = <<~GNT
      <template>
        <div data-component="x">A</div>
      </template>

      <template data-template="row">
        <li>B</li>
      </template>

      <template>
        <div data-component="y">C</div>
      </template>

      <script type="text/ruby">
        class X < Lilac::Component; end
      </script>
    GNT

    comp = Lilac::CLI::SFC.parse(source)
    assert_equal 3, comp.templates.length
    assert_nil comp.templates[0].name
    assert_equal "row", comp.templates[1].name
    assert_nil comp.templates[2].name
    assert_includes comp.templates[0].body, "A"
    assert_includes comp.templates[1].body, "B"
    assert_includes comp.templates[2].body, "C"
  end

  def test_multiple_script_blocks_concatenated
    source = <<~GNT
      <script type="text/ruby">
        class A < Lilac::Component; end
      </script>

      <template></template>

      <script type="text/ruby">
        class B < Lilac::Component; end
      </script>
    GNT

    comp = Lilac::CLI::SFC.parse(source)
    assert_includes comp.script, "class A"
    assert_includes comp.script, "class B"
  end

  def test_preserves_inner_html_verbatim
    body = "  <div>\n    <span>hi</span>\n  </div>\n"
    source = "<template>#{body}</template><script type=\"text/ruby\">x = 1</script>"
    comp = Lilac::CLI::SFC.parse(source)
    assert_equal body, comp.templates.first.body
  end

  def test_unterminated_template_raises
    err = assert_raises(Lilac::CLI::SFC::ParseError) do
      Lilac::CLI::SFC.parse("<template>oops")
    end
    assert_match(/Unterminated <template>/, err.message)
  end

  def test_unterminated_script_raises
    err = assert_raises(Lilac::CLI::SFC::ParseError) do
      Lilac::CLI::SFC.parse('<script type="text/ruby">oops')
    end
    assert_match(/Unterminated <script/, err.message)
  end

  def test_empty_source_yields_empty_component
    comp = Lilac::CLI::SFC.parse("")
    assert_empty comp.templates
    assert_equal "", comp.script
  end

  def test_top_level_html_comment_is_ignored
    source = <<~GNT
      <!-- a top-level comment that must not confuse the parser -->
      <template>X</template>
      <script type="text/ruby">y = 1</script>
    GNT
    comp = Lilac::CLI::SFC.parse(source)
    assert_equal "X", comp.templates.first.body
    assert_includes comp.script, "y = 1"
  end

  def test_non_ruby_script_is_ignored
    # <script> without type="text/ruby" must NOT be slurped.
    source = <<~GNT
      <script>console.log("ignored")</script>
      <template>X</template>
      <script type="text/ruby">y = 1</script>
    GNT
    comp = Lilac::CLI::SFC.parse(source)
    assert_equal "X", comp.templates.first.body
    assert_includes comp.script, "y = 1"
    refute_includes comp.script, "console.log"
  end

  # ---- extract_inline_ruby_scripts (page HTML helper) ---------------

  def test_extract_inline_ruby_scripts_returns_sources_and_strips
    html = <<~HTML
      <html><body>
      <h1>Title</h1>
      <script type="text/ruby">
      class Foo; end
      </script>
      <p>done</p>
      </body></html>
    HTML

    result = Lilac::CLI::SFC.extract_inline_ruby_scripts(html)
    assert_equal 1, result[:scripts].length
    assert_includes result[:scripts].first, "class Foo; end"
    refute_includes result[:stripped_html], '<script type="text/ruby">'
    refute_includes result[:stripped_html], "class Foo"
    assert_includes result[:stripped_html], "<h1>Title</h1>"
    assert_includes result[:stripped_html], "<p>done</p>"
  end

  def test_extract_inline_ruby_scripts_multiple_blocks_in_order
    html = <<~HTML
      <body>
      <script type="text/ruby">class A; end</script>
      <div>middle</div>
      <script type="text/ruby">class B; end</script>
      </body>
    HTML

    result = Lilac::CLI::SFC.extract_inline_ruby_scripts(html)
    assert_equal 2, result[:scripts].length
    assert_includes result[:scripts][0], "class A"
    assert_includes result[:scripts][1], "class B"
    refute_includes result[:stripped_html], "class A"
    refute_includes result[:stripped_html], "class B"
    assert_includes result[:stripped_html], "<div>middle</div>"
  end

  def test_extract_inline_ruby_scripts_ignores_other_script_types
    html = <<~HTML
      <body>
      <script type="module">import x from "/y.js";</script>
      <script>console.log("plain");</script>
      <script type="text/ruby">class Only; end</script>
      </body>
    HTML

    result = Lilac::CLI::SFC.extract_inline_ruby_scripts(html)
    assert_equal 1, result[:scripts].length
    assert_includes result[:scripts].first, "class Only"
    # Non-ruby script tags must survive untouched.
    assert_includes result[:stripped_html], '<script type="module">'
    assert_includes result[:stripped_html], 'console.log("plain")'
  end

  def test_extract_inline_ruby_scripts_unterminated_raises
    html = %(<body><script type="text/ruby">class A; end</body>)
    assert_raises(Lilac::CLI::SFC::ParseError) do
      Lilac::CLI::SFC.extract_inline_ruby_scripts(html, path: "fake.html")
    end
  end

  def test_extract_inline_ruby_scripts_no_match_returns_html_unchanged
    html = "<html><body><h1>plain</h1></body></html>"
    result = Lilac::CLI::SFC.extract_inline_ruby_scripts(html)
    assert_empty result[:scripts]
    assert_equal html, result[:stripped_html]
  end
end
