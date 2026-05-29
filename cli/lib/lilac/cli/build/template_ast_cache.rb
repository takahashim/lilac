# frozen_string_literal: true

require_relative "template_ast"

module Lilac
  module CLI
    # Memoizes parsed component template ASTs by component name. The
    # same `.lil` shape often appears on many pages; the parse step is
    # not free and the parsed result is immutable, so caching once per
    # build keeps multi-page builds linear in components rather than
    # `pages × components`.
    #
    # Shared by `Builder` (when emitting the :bundle delivery file) and
    # `PageCompiler` (per-page injection). Both read through `fetch`;
    # writes happen lazily on miss.
    class TemplateASTCache
      # A user-defined named template (from `<template data-template="...">`
      # in `.lil` source) ready to be injected as `<template
      # data-template="X">` into the page.
      RenderedTemplate = Struct.new(:name, :html, keyword_init: true)

      def initialize
        @cache = {}
      end

      # Returns a Hash with:
      #   :default_html        — concatenated body HTML of the default templates
      #   :default_directives  — Array<Directive> for top-level binding emission
      #   :default_refs_map    — Hash { ref_name => line } for lint
      #   :named               — Array<RenderedTemplate> (user-defined)
      #   :source_path         — Path to the `.lil` (or in-memory page)
      def fetch(name, component)
        @cache[name] ||= parse(component)
      end

      private

      def parse(component)
        default_results = component.default_templates.map do |t|
          TemplateAST.new(t.body, source_path: component.path).parse
        end

        named = component.named_templates.map do |t|
          result = TemplateAST.new(t.body, source_path: component.path).parse
          RenderedTemplate.new(name: t.name, html: result.html)
        end

        {
          default_html: default_results.map(&:html).join.strip,
          default_directives: default_results.flat_map(&:directives),
          default_refs_map: default_results.map(&:refs_map).reduce({}, :merge),
          named: named,
          source_path: component.path
        }
      end
    end
  end
end
