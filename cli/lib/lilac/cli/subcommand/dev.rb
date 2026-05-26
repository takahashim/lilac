# frozen_string_literal: true

require_relative "base"
require_relative "../config"
require_relative "../dev_server"

module Lilac
  module CLI
    module Subcommand
      class Dev < Base
        def run
          opts = parse_opts

          # `--target` for `lilac dev` controls the watch-rebuild path.
          # Defaults to `c.dev_target` (Config DEFAULT is `:full`) — the
          # `:compiled` path will fire `mrbc` on every change once the
          # DevServer wiring lands (Phase 2 of the proposals.md entry).
          config = Config.load(
            root: opts[:root],
            components_dir: opts[:components],
            pages_dir: opts[:pages],
            output_dir: opts[:output],
            public_dir: opts[:public],
            dev_host: opts[:host],
            dev_port: opts[:port],
            dev_target: opts[:target],
            mrbc_path: opts[:mrbc_path],
            lilac_compiled_path: opts[:lilac_compiled_path],
            mruby_wasm_js_path: opts[:mruby_wasm_js_path],
          )

          DevServer.new(
            config,
            host: config.dev_host,
            port: config.dev_port,
            out: @out,
            err: @err,
          ).start
          0
        end

        private

        def opts_parser(opts = {})
          OptionParser.new do |o|
            o.banner = "Usage: lilac dev [options]"
            o.on("--host HOST", "Bind host (default: #{Config::DEFAULT_DEV_HOST})") { |v| opts[:host] = v }
            o.on("--port PORT", Integer, "Bind port (default: #{Config::DEFAULT_DEV_PORT})") { |v| opts[:port] = v }
            OptionHelpers.add_path_options(o, opts)
            OptionHelpers.add_target_options(o, opts)
            o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
          end
        end
      end
    end
  end
end
