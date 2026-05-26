# frozen_string_literal: true

require "fileutils"
require_relative "base"
require_relative "../config"
require_relative "../build/builder"

module Lilac
  module CLI
    module Subcommand
      class Build < Base
        def run
          opts = parse_opts

          config = Config.load(
            root: opts[:root],
            components_dir: opts[:components],
            pages_dir: opts[:pages],
            output_dir: opts[:output],
            public_dir: opts[:public],
            build_target: opts[:target],
            mrbc_path: opts[:mrbc_path],
            lilac_compiled_path: opts[:lilac_compiled_path],
            mruby_wasm_js_path: opts[:mruby_wasm_js_path],
          )

          # Default to clean: stale per-page `.mrb` (whose content hash
          # changed across builds) would otherwise accumulate, and most
          # modern build tools (Vite / Next / Eleventy / Webpack 5)
          # follow the same convention. Opt out with `--no-clean` for
          # incremental inspection or when something outside Lilac
          # populates the same dist directory.
          clean_output_dir!(config.output_dir, project_root: config.root) unless opts[:clean] == false

          result = Builder.from_config(config).build
          public_suffix = result[:public_files].positive? ? " + #{result[:public_files]} static file(s)" : ""
          @out.puts "Built #{result[:pages]} page(s) from #{result[:components]} component(s)#{public_suffix} " \
                    "→ #{relative(config.output_dir)} (target: #{config.build_target})"
          0
        end

        private

        def opts_parser(opts = {})
          OptionParser.new do |o|
            o.banner = "Usage: lilac build [options]"
            OptionHelpers.add_path_options(o, opts)
            OptionHelpers.add_target_options(o, opts)
            o.on("--[no-]clean", "Remove the output dir before building (default: true)") do |v|
              opts[:clean] = v
            end
            o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
          end
        end

        # `--clean` wipes the output dir before building so old artefacts
        # (e.g. stale per-page `.mrb` bundles whose content hash changed)
        # don't accumulate. We refuse to wipe paths that look dangerous —
        # the project root (so `output_dir = "."` doesn't nuke the source),
        # a filesystem root, the user's home dir. Raises `Builder::Error`
        # (caught by the top-level `Command#run` rescue) rather than
        # exiting, so tests and embedders see the error as a normal
        # non-zero return.
        def clean_output_dir!(output_dir, project_root:)
          path = File.expand_path(output_dir.to_s)
          forbidden = [
            "/",
            File.expand_path(Dir.home),
            File.expand_path(project_root.to_s),
          ]
          if forbidden.include?(path)
            raise Builder::Error,
                  "--clean refused: output_dir #{output_dir.inspect} resolves to a root / home / project dir " \
                  "(this would delete your project). Set `output_dir` to a dedicated subdir like `dist/`."
          end
          FileUtils.rm_rf(path) if File.exist?(path)
        end
      end
    end
  end
end
