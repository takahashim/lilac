# frozen_string_literal: true

require_relative "template_ast"
require_relative "component_name"

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
      # A template ready to be injected as `<template data-template="X">`
      # into the page. Both user-defined named templates (from
      # `<template data-template="...">` in `.lil` source) and synthetic
      # data-each iteration bodies extracted by TemplateAST end up as
      # this single shape — the page-injection logic doesn't need to
      # know which side they came from.
      RenderedTemplate = Struct.new(:name, :html, keyword_init: true)

      def initialize
        @cache = {}
      end

      # Returns a Hash with:
      #   :default_html        — concatenated body HTML of the default templates
      #   :default_directives  — Array<Directive> for top-level binding emission
      #   :default_refs_map    — Hash { ref_name => { line:, ... } } for lint
      #   :named               — Array<RenderedTemplate> (user + synthetic)
      #   :source_path         — Path to the `.lil` (or in-memory page)
      #
      # `data-each` iteration bodies extracted by TemplateAST are folded
      # into `:named` as synthetic templates using
      # `ComponentName#each_template_name` so they ride the same
      # `<template data-template>` injection path as user-defined named
      # templates and the runtime can resolve them via
      # `bind_list ..., template: "lil-each-<component>-<ref>"`.
      def fetch(name, component)
        @cache[name] ||= parse(name, component)
      end

      private

      def parse(name, component)
        component_name = ComponentName.new(name)

        default_results = component.default_templates.map do |t|
          TemplateAST.new(t.body, source_path: component.path).parse
        end

        named = component.named_templates.map do |t|
          result = TemplateAST.new(t.body, source_path: component.path).parse
          RenderedTemplate.new(name: t.name, html: result.html)
        end

        synthetic = default_results.flat_map(&:synthetic_templates).map do |st|
          RenderedTemplate.new(
            name: component_name.each_template_name(st.ref_id),
            html: st.html
          )
        end

        {
          default_html: default_results.map(&:html).join.strip,
          default_directives: default_results.flat_map(&:directives),
          default_refs_map: default_results.map(&:refs_map).reduce({}, :merge),
          named: named + synthetic,
          source_path: component.path
        }
      end
    end
  end
end
