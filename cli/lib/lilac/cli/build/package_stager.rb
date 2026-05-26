# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative '../package_discovery'

module Lilac
  module CLI
    # Stages Lilac package `.mrb` files under `dist/packages/` and (for
    # the :full target) writes the `lilac.packages.json` manifest the
    # scaffold-style boot script reads to load each package ahead of
    # `evalScript`.
    #
    # Two input channels merge here (decisions §25 / §26):
    #
    #   1. **Bundler auto-discovery** — `PackageDiscovery.run` finds gems
    #      whose gemspec declares `metadata["lilac_package"] = "true"`.
    #      Each gem's `mrblib/*.rb` is compiled locally to `.mrb` so the
    #      mruby version matches the vendored core wasm.
    #   2. **Explicit `c.packages = [...paths]`** — pre-compiled `.mrb`
    #      files. Useful for advanced overrides (custom package not in
    #      a gem, vendored fork, etc.).
    #
    # Manifest emission is target-dependent:
    #   - `:full` writes `dist/lilac.packages.json` so the user's hand-
    #     rolled boot script can `fetch` it and `loadBytecode` each entry
    #   - `:compiled` skips the manifest — the generated boot module
    #     inlines `loadBytecode` calls directly
    #
    # Sibling of `BundleAssetWriter` / `VendorWriter`: same shape (a
    # build phase owning one cluster of file emissions), invoked once
    # from `Builder#build`.
    class PackageStager
      PACKAGES_DIR = 'packages'
      MANIFEST_FILENAME = 'lilac.packages.json'

      def initialize(packages:, target:, output_dir:, bytecode_builder:)
        @packages = packages
        @target = target
        @output_dir = output_dir
        @bytecode_builder = bytecode_builder
      end

      # Returns `Array<String>` — page-relative URLs of every staged
      # `.mrb`. Empty when no packages are configured or discovered.
      def run!
        return [] if @packages.empty? && discovered_packages.empty?

        FileUtils.mkdir_p(File.join(@output_dir, PACKAGES_DIR))
        urls = (stage_discovered + stage_explicit).uniq
        write_manifest!(urls) if @target == :full
        urls
      end

      private

      # Cached so multi-page builds discover once. Empty list outside
      # a Bundler context.
      def discovered_packages
        @discovered_packages ||= PackageDiscovery.run
      end

      # Auto-discovered gem-based packages first. Compile each gem's
      # mrblib source set to a single `.mrb` named after the gem so
      # filename collisions with explicit override paths are easy to
      # spot.
      def stage_discovered
        discovered_packages.map do |discovered|
          bytes = compile_source(discovered.mrblib_files, source_label: discovered.name)
          filename = "#{discovered.name}.mrb"
          File.binwrite(File.join(@output_dir, PACKAGES_DIR, filename), bytes)
          "./#{PACKAGES_DIR}/#{filename}"
        end
      end

      # Explicit override paths next — already-compiled `.mrb` files
      # the user pointed at directly via `c.packages`.
      def stage_explicit
        @packages.map do |src|
          raise Builder::Error, "Lilac package `.mrb` not found: #{src}" unless File.file?(src)

          basename = File.basename(src)
          FileUtils.cp(src, File.join(@output_dir, PACKAGES_DIR, basename))
          "./#{PACKAGES_DIR}/#{basename}"
        end
      end

      # Compile concatenated mrblib source via the shared
      # `BytecodeBuilder` backend chain (binary mrbc → wasm-driven mrbc
      # → $PATH). Mirrors `lilac package-build`'s aggregation rule:
      # alphabetical concat separated by newlines.
      def compile_source(mrblib_files, source_label:)
        source = mrblib_files.map { |f| File.read(f) }.join("\n")
        @bytecode_builder.compile_to_bytes(source, source_label: "package #{source_label}")
      end

      # Write `dist/lilac.packages.json` so a scaffold-style boot script
      # can fetch the manifest and `loadBytecode` each entry before
      # evaluating `<script type="text/ruby">` blocks. The manifest is
      # only written when at least one package was staged, so absence of
      # the file means "no packages" — boot scripts can fetch with a
      # graceful 404 fallback.
      def write_manifest!(package_urls)
        return if package_urls.empty?

        manifest_path = File.join(@output_dir, MANIFEST_FILENAME)
        File.write(manifest_path, JSON.pretty_generate(packages: package_urls) + "\n")
      end
    end
  end
end
