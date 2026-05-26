# frozen_string_literal: true

require_relative "base"
require_relative "../config"
require_relative "../doctor"

module Lilac
  module CLI
    module Subcommand
      class Doctor < Base
        def run
          opts = parse_opts

          config = Config.load(
            root: opts[:root],
            components_dir: opts[:components],
            pages_dir: opts[:pages],
            output_dir: opts[:output],
            public_dir: opts[:public],
          )

          # Fully qualify the outer Doctor class to disambiguate from
          # the enclosing `Subcommand::Doctor` we're inside.
          ::Lilac::CLI::Doctor.new(config, out: @out).run
        end

        private

        def opts_parser(opts = {})
          OptionParser.new do |o|
            o.banner = "Usage: lilac doctor [options]"
            OptionHelpers.add_path_options(o, opts)
            o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
          end
        end
      end
    end
  end
end
