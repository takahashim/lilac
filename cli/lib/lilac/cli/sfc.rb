# frozen_string_literal: true

module Lilac
  module CLI
    # Parses a `.llc` single-file component into its constituent parts:
    #
    #   * one or more `<template>` blocks, optionally named via
    #     `data-template="..."` (a standard HTML5 data attribute, same as
    #     what the Lilac runtime expects for clone-targets)
    #   * one or more `<script type="text/ruby">` blocks
    #
    # The format is HTML5-valid: any conformant HTML parser (browser,
    # nokogiri, gammo) can build a DOM from a `.llc` file. We use regex
    # rather than a full HTML parser internally because we want the
    # `<template>` inner content **verbatim** — a DOM-based parser would
    # require re-serializing children back to HTML and would normalize
    # quote / whitespace / attribute order along the way.
    #
    # The parsed result is a `Component` value object. Order of templates
    # is preserved from the source; named templates remember their name.
    # Anonymous templates (no `data-template` attribute) are the
    # component's "default" markup; multiple anonymous templates are
    # allowed and concatenated in document order.
    module SFC
      # `name` is nil for anonymous templates.
      Template = Struct.new(:name, :body, keyword_init: true)

      # `path` is the source file path (or nil for in-memory parses).
      # `templates` is an Array<Template>, `script` is a single concatenated
      # String of all Ruby blocks joined by a newline.
      Component = Struct.new(:path, :templates, :script, keyword_init: true) do
        def default_templates
          templates.select { |t| t.name.nil? }
        end

        def named_templates
          templates.reject { |t| t.name.nil? }
        end
      end

      class ParseError < StandardError; end

      TEMPLATE_OPEN = /<template(?:\s+data-template="([^"]*)")?\s*>/
      TEMPLATE_CLOSE = "</template>"
      SCRIPT_OPEN = /<script\s+type="text\/ruby"\s*>/
      SCRIPT_CLOSE = "</script>"

      def self.parse_file(path)
        parse(File.read(path), path: path)
      end

      # Walks the source linearly so nested `<template>` / `<script>` tags
      # don't get matched by a greedy regex. Each iteration:
      #   1. find the earliest opening tag (template or script)
      #   2. find its matching close, extract the body
      #   3. advance past the close
      def self.parse(source, path: nil)
        templates = []
        script_parts = []
        cursor = 0

        while cursor < source.length
          tmpl_match = source.match(TEMPLATE_OPEN, cursor)
          script_match = source.match(SCRIPT_OPEN, cursor)

          # Earlier of the two openings wins; nil-safe sort by offset.
          next_match = [tmpl_match, script_match].compact
                                                 .min_by { |m| m.begin(0) }
          break unless next_match

          if next_match == tmpl_match
            templates << extract_template(source, tmpl_match, path)
            cursor = source.index(TEMPLATE_CLOSE, tmpl_match.end(0)) + TEMPLATE_CLOSE.length
          else
            script_parts << extract_script(source, script_match, path)
            cursor = source.index(SCRIPT_CLOSE, script_match.end(0)) + SCRIPT_CLOSE.length
          end
        end

        Component.new(
          path: path,
          templates: templates,
          script: script_parts.join("\n"),
        )
      end

      def self.extract_template(source, match, path)
        name = match[1].to_s.empty? ? nil : match[1]
        body_start = match.end(0)
        body_end = source.index(TEMPLATE_CLOSE, body_start)
        raise ParseError, "Unterminated <template> in #{path || '<input>'}" unless body_end

        Template.new(name: name, body: source[body_start...body_end])
      end

      def self.extract_script(source, match, path)
        body_start = match.end(0)
        body_end = source.index(SCRIPT_CLOSE, body_start)
        raise ParseError, "Unterminated <script type=\"text/ruby\"> in #{path || '<input>'}" unless body_end

        source[body_start...body_end]
      end
    end
  end
end
