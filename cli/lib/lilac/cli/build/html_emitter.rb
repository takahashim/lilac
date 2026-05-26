# frozen_string_literal: true

module Lilac
  module CLI
    # Pure HTML string-rendering helpers shared by `Builder` (bundle file
    # emission) and `PageCompiler` (per-page injection). Keeping these as
    # module functions makes the dependency direction obvious (stateless
    # utilities) and trims surface area from the larger classes.
    module HtmlEmitter
      module_function

      def render_named_template(template_name, body_html)
        %(<template data-template="#{escape_attr(template_name)}">#{body_html}</template>)
      end

      # Emit a <template> wrapping the component's default markup. The
      # `default_html` already contains the outer `<div data-component="X">`
      # element from the .lil source, so we don't add another wrapper —
      # just surround it with <template> so the runtime registry can pick
      # it up as the source for data-use="X" injections.
      def render_default_template(default_html)
        %(<template>#{default_html}</template>)
      end

      def render_script(ruby_source)
        "<script type=\"text/ruby\">\n#{ruby_source}\n</script>"
      end

      def escape_attr(value)
        value.gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;')
      end

      # Splice text just before the page's </body>. Prefers the last
      # </body> in the source so any earlier mention (e.g. inside a
      # <pre> code example) doesn't get hijacked.
      def inject_before_body_close(html, injection)
        idx = html.rindex(%r{</body>}i)
        return "#{html}\n#{injection}" unless idx

        "#{html[0...idx]}#{injection}\n#{html[idx..]}"
      end

      # Inject `<link rel="lilac-bundle" href="...">` into the page's
      # <head>. Falls back to before <body>, then to a prepend, when the
      # page HTML is handwritten without standard boundary tags.
      def inject_bundle_link(html, url)
        link = %(<link rel="lilac-bundle" href="#{escape_attr(url)}">)
        if html =~ %r{</head>}i
          html.sub(%r{</head>}i, "  #{link}\n</head>")
        elsif html =~ %r{<body}i
          html.sub(%r{<body}i, "#{link}\n<body")
        else
          "#{link}\n#{html}"
        end
      end
    end
  end
end
