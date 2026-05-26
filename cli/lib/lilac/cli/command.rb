# frozen_string_literal: true

require_relative "subcommand/build"
require_relative "subcommand/dev"
require_relative "subcommand/preview"
require_relative "subcommand/new"
require_relative "subcommand/doctor"
require_relative "subcommand/package_build"

module Lilac
  module CLI
    # Entry point for `exe/lilac`. Routes argv[0] to the matching
    # `Subcommand::*` handler; each subcommand owns its own OptionParser
    # and `run` method. The outer rescue here keeps the user-facing
    # error surface uniform (Builder::Error / ConfigLoader::LoadError /
    # etc. → "lilac: <msg>" + exit 1).
    class Command
      SUBCOMMAND_HANDLERS = {
        "build"         => Subcommand::Build,
        "dev"           => Subcommand::Dev,
        "preview"       => Subcommand::Preview,
        "new"           => Subcommand::New,
        "doctor"        => Subcommand::Doctor,
        "package-build" => Subcommand::PackageBuild,
      }.freeze

      def initialize(argv, out: $stdout, err: $stderr)
        @argv = argv.dup
        @out = out
        @err = err
      end

      # Returns an exit status (0 for success).
      def run
        name = @argv.shift || "help"

        return print_version if name == "--version"
        return run_help if %w[help -h --help].include?(name)

        if (handler = SUBCOMMAND_HANDLERS[name])
          handler.new(@argv, out: @out, err: @err).run
        else
          @err.puts "lilac: unknown command #{name.inspect}"
          @err.puts
          print_help(io: @err)
          1
        end
      rescue Builder::Error, SFC::ParseError, Scaffold::Error,
             ConfigLoader::LoadError, PreviewServer::Error,
             PackageBuild::Error => e
        @err.puts "lilac: #{e.message}"
        1
      end

      # `lilac help` shows the top-level help; `lilac help <subcmd>`
      # shows the per-subcommand option list (sourced from the same
      # OptionParser that the subcommand uses, so it stays in sync).
      def run_help
        topic = @argv.shift
        case topic
        when nil, "help", "-h", "--help"
          print_help
          0
        else
          if (handler = SUBCOMMAND_HANDLERS[topic])
            @out.puts handler.help_text
            0
          else
            @err.puts "lilac help: unknown command #{topic.inspect}"
            @err.puts
            print_help(io: @err)
            1
          end
        end
      end

      private

      def print_help(io: @out)
        io.puts <<~HELP
          lilac — build .lil single-file components into static HTML

          Usage:
            lilac <command> [options]

          Commands:
            new <name>  Scaffold a new Lilac app
            build       Compile components/ + pages/ into dist/
            dev         Build, serve, watch — live reload on changes
            preview     Serve the built dist/ as a static site (no watch / reload)
            doctor      Verify project setup (runtime, references, paths)
            package-build  Compile pure-Ruby package source(s) to `.mrb` bytecode
            help        Show this help
            --version   Print version

          Tip: place the mruby-wasm runtime under public/vendor/. Run
          `lilac doctor` to check the setup.

          Run `lilac help <command>` or `lilac <command> --help` for
          command-specific options.
        HELP
      end

      def print_version
        @out.puts "lilac-cli #{VERSION}"
        0
      end
    end
  end
end
