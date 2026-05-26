# frozen_string_literal: true

require_relative "../config"

module Lilac
  module CLI
    module Subcommand
      # Shared OptionParser option groups. `build` / `dev` / `doctor` /
      # `preview` accept the same path-config flags; `build` / `dev`
      # additionally accept the target / mrbc / runtime flags. Keeping
      # these here so the subcommand classes don't drift out of sync.
      module OptionHelpers
        module_function

        # The path-config flags `build` / `dev` / `doctor` / `preview`
        # all accept. `o.on` mutates the OptionParser passed in; `opts`
        # collects the parsed values for the caller's later Config.load
        # merge.
        def add_path_options(o, opts)
          o.on("--components DIR", "Components directory (default: components)") { |v| opts[:components] = v }
          o.on("--pages DIR", "Pages directory (default: pages)") { |v| opts[:pages] = v }
          o.on("--public DIR", "Static-passthrough directory (default: public)") { |v| opts[:public] = v }
          o.on("--output DIR", "-o DIR", "Output directory (default: dist)") { |v| opts[:output] = v }
          o.on("--root DIR", "Project root (default: cwd)") { |v| opts[:root] = v }
        end

        # Build / dev target selection. `--target full` produces dist HTML
        # with inline Ruby + lilac-full wasm (original Lilac story).
        # `--target compiled` invokes `mrbc` to produce `.mrb` bytecode +
        # lilac-compiled wasm (smaller production bundle, ~32% brotli).
        # `--mrbc-path` lets the user pin a specific mrbc binary when the
        # auto-discovery would pick the wrong one.
        def add_target_options(o, opts)
          o.on("--target TARGET", Config::TARGET_VALUES.map(&:to_s),
               "Build target (#{Config::TARGET_VALUES.join(' / ')}; default: full)") do |v|
            opts[:target] = v.to_sym
          end
          o.on("--mrbc-path PATH",
               "Path to the mrbc binary (default: auto-discover)") do |v|
            opts[:mrbc_path] = v
          end
          o.on("--lilac-compiled-path PATH",
               "Path to lilac-compiled.wasm (default: auto-discover; --target compiled only)") do |v|
            opts[:lilac_compiled_path] = v
          end
          o.on("--mruby-wasm-js-path PATH",
               "Path to the mruby-wasm-js bridge directory (default: auto-discover; --target compiled only)") do |v|
            opts[:mruby_wasm_js_path] = v
          end
        end
      end
    end
  end
end
