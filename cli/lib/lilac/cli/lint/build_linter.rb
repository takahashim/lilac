# frozen_string_literal: true

require "digest"
require_relative "script_analyzer"
require_relative "../build/component_name"

module Lilac
  module CLI
    # Build-time linter for component-name / cross-page consistency.
    # Extracted from `Builder` so the build pipeline itself stays focused
    # on HTML rewriting + bytecode emission. Owns the per-build state
    # (page-inline component signatures) that drives cross-page drift
    # detection.
    class BuildLinter
      def initialize
        # `{ component_name => [ [content_hash, page_path], ... ] }`
        # for every page-inline `data-component` element across pages.
        # Populated via `record_inline_signature` from the builder.
        @page_inline_signatures = Hash.new { |h, k| h[k] = [] }
      end

      # R4: page-inline script classes that collide with `.lil`-derived
      # class names (project-global) are flagged before codegen so the
      # user sees a structured error instead of a downstream Codegen /
      # mrbc failure. Raises `Lilac::CLI::Builder::Error` to match the
      # error surface other build-time scope violations use.
      def check_class_name_collisions!(page_inline_scripts, components, synthesized_names, page_path)
        return if page_inline_scripts.empty?

        # `.lil` class names (skip synthesized in-memory entries — those
        # are the page-inline data-component snapshots, not real .lil files).
        lil_class_names = {} # ruby_class_name => kebab (original file)
        components.each_key do |name|
          next if synthesized_names.include?(name)

          ruby_name = ComponentName.new(name).ruby_class
          lil_class_names[ruby_name] = name
        end
        return if lil_class_names.empty?

        page_inline_scripts.each do |script|
          ScriptAnalyzer.extract_top_level_class_names(script).each do |declared|
            next unless lil_class_names.key?(declared)

            page_rel = page_path ? File.basename(page_path) : '(page)'
            lil_basename = "#{lil_class_names[declared]}.lil"
            raise Lilac::CLI::Builder::Error,
                  "page-inline class #{declared} in #{page_rel} collides with the class " \
                  "derived from components/#{lil_basename}. " \
                  "Rename either the page-inline class or the .lil file."
          end
        end
      end

      # Records a page-inline component's body signature so
      # `warn_cross_page_signature_drift!` can later detect divergent
      # shapes of the same name across pages.
      def record_inline_signature(name, body_html, page_path)
        @page_inline_signatures[name] << [signature_for(body_html), page_path]
      end

      # R3: after every page is built, scan recorded signatures for the
      # same name appearing with different content_hashes across pages.
      # Output a single warning grouping divergent pages so the user can
      # decide whether to rename one of them or align the shapes.
      def warn_cross_page_signature_drift!
        @page_inline_signatures.each do |name, entries|
          unique_sigs = entries.map { |sig, _| sig }.uniq
          next if unique_sigs.size <= 1

          pages_str = entries.uniq { |sig, _| sig }
                             .map { |_sig, page| File.basename(page) }
                             .join(', ')
          warn(
            "[lilac] page-inline component #{name.inspect} appears with " \
            "different shapes across pages (#{pages_str}). " \
            "Page-inline names are page-local so this is allowed, but " \
            "is likely unintentional drift — consider renaming or moving " \
            "the component to components/#{name}.lil to share one shape."
          )
        end
      end

      private

      # Stable hash of a page-inline component element body (outer HTML)
      # for cross-page drift detection (proposal §A.R3). Whitespace
      # normalised so cosmetic indentation differences across pages don't
      # spuriously fire the warning.
      def signature_for(body_html)
        Digest::SHA1.hexdigest(body_html.gsub(/\s+/, ' ').strip)
      end
    end
  end
end
