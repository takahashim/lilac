# frozen_string_literal: true

require_relative "base"
require_relative "../package_build"

module Lilac
  module CLI
    module Subcommand
      class PackageBuild < Base
        def run
          opts = parse_opts

          if opts[:output].nil?
            @err.puts "Usage: lilac package-build <input.rb>... -o <output.mrb>"
            return 1
          end
          if @argv.empty?
            @err.puts "lilac package-build: at least one input file required"
            @err.puts "Usage: lilac package-build <input.rb>... -o <output.mrb>"
            return 1
          end

          # Fully qualify the outer engine class to disambiguate from
          # the enclosing `Subcommand::PackageBuild` we're inside.
          package = ::Lilac::CLI::PackageBuild.new(
            inputs: @argv.dup,
            output: opts[:output],
            mrbc_path: opts[:mrbc_path],
          )
          out_path = package.run
          @out.puts "Built package bytecode: #{relative(out_path)} (#{File.size(out_path)} bytes)"
          0
        end

        private

        def opts_parser(opts = {})
          OptionParser.new do |o|
            o.banner = "Usage: lilac package-build <input.rb>... -o <output.mrb>"
            o.on("-o", "--output PATH", "Output `.mrb` file (required)") { |v| opts[:output] = v }
            o.on("--mrbc-path PATH",
                 "Path to the mrbc binary (default: auto-discover via lilac-wasm-bin)") do |v|
              opts[:mrbc_path] = v
            end
            o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
          end
        end
      end
    end
  end
end
