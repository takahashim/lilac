# frozen_string_literal: true

require_relative "base"
require_relative "../config"
require_relative "../preview_server"

module Lilac
  module CLI
    module Subcommand
      class Preview < Base
        def run
          opts = parse_opts

          # `preview` only needs the output_dir resolved; target / mrbc /
          # vendor paths are irrelevant because we're serving an already-
          # built `dist/`. Reuse `Config.load` so `lilac.config.rb` is
          # still consulted for `output_dir`.
          config = Config.load(
            root: opts[:root],
            components_dir: opts[:components],
            pages_dir: opts[:pages],
            output_dir: opts[:output],
            public_dir: opts[:public],
          )

          PreviewServer.new(
            config.output_dir,
            host: opts[:host] || PreviewServer::DEFAULT_HOST,
            port: opts[:port] || PreviewServer::DEFAULT_PORT,
            out: @out,
            err: @err,
          ).start
          0
        end

        private

        def opts_parser(opts = {})
          OptionParser.new do |o|
            o.banner = "Usage: lilac preview [options]"
            o.on("--host HOST", "Bind host (default: #{PreviewServer::DEFAULT_HOST})") { |v| opts[:host] = v }
            o.on("--port PORT", Integer, "Bind port (default: #{PreviewServer::DEFAULT_PORT})") { |v| opts[:port] = v }
            OptionHelpers.add_path_options(o, opts)
            o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
          end
        end
      end
    end
  end
end
