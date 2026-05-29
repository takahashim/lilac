# frozen_string_literal: true

module Lilac
  module CLI
    # Walks `Bundler.load.specs` to find gems that declare themselves as
    # Lilac packages via `metadata["lilac_package"] == "true"`.
    #
    # Each entry is described by `Discovered` (gem name, version, mrblib
    # source files). `Builder` feeds the source files into
    # `PackageBuild#compile_to_bytes` at build time and stages the
    # produced `.mrb` under `dist/packages/`.
    #
    # If Bundler isn't loaded (e.g. `lilac-cli` is being run from a
    # context without a Gemfile), discovery silently returns an empty
    # list. Users who want explicit control set
    # `c.packages = [...paths]` in `lilac.config.rb`, which goes through
    # a different code path and bypasses discovery.
    class PackageDiscovery
      # Metadata key on a gemspec that marks the gem as a Lilac package.
      # Set via `spec.metadata["lilac_package"] = "true"` in the
      # `lilac-*.gemspec`.
      METADATA_KEY = "lilac_package"

      Discovered = Struct.new(:name, :mrblib_files, keyword_init: true)

      def self.run
        new.run
      end

      # Returns Array<Discovered>. Empty when Bundler isn't loaded or
      # when no Lilac packages are declared in the current Gemfile.
      def run
        return [] unless bundler_loaded?

        bundler_specs.filter_map do |spec|
          next unless package_spec?(spec)

          files = mrblib_files_for(spec)
          next if files.empty?

          Discovered.new(name: spec.name, mrblib_files: files)
        end
      end

      private

      # `Bundler.load.specs` (vs `Bundler.definition.specs`) returns the
      # set of gems active in the current bundle — i.e. what's actually
      # available to `require`. That's exactly the lens we want: packages
      # listed in the user's Gemfile but uninstalled (or absent) are
      # skipped silently rather than raising mid-build.
      def bundler_specs
        Bundler.load.specs.to_a
      rescue Bundler::GemfileNotFound, Bundler::BundlerError
        # Outside a bundle / Gemfile-less project: no packages to find.
        # Explicit `c.packages` paths still work — see `Config#packages`.
        []
      end

      def bundler_loaded?
        defined?(Bundler) && Bundler.respond_to?(:load)
      end

      def package_spec?(spec)
        spec.metadata && spec.metadata[METADATA_KEY] == "true"
      end

      # mrblib source lives at `mrblib/**/*.rb` in each package gem's
      # root. Returns absolute paths in alphabetical order so the
      # concatenation (`PackageBuild#aggregate_sources`) is deterministic.
      def mrblib_files_for(spec)
        base = spec.full_gem_path
        Dir[File.join(base, "mrblib", "**", "*.rb")].sort
      end
    end
  end
end
