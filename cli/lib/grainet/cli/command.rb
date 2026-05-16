# frozen_string_literal: true

require "optparse"
require_relative "config"
require_relative "builder"
require_relative "dev_server"
require_relative "scaffold"
require_relative "doctor"

module Grainet
  module CLI
    # Entry point for `exe/grainet`. Routes the first non-option argument
    # to a subcommand handler. Subcommands are kept inline here; revisit
    # splitting them into their own files when this class crosses
    # ~250 lines or grows past 5 subcommands.
    class Command
      SUBCOMMANDS = %w[build dev new doctor help].freeze

      def initialize(argv, out: $stdout, err: $stderr)
        @argv = argv.dup
        @out = out
        @err = err
      end

      # Returns an exit status (0 for success).
      def run
        subcommand = @argv.shift || "help"
        case subcommand
        when "build" then run_build
        when "dev" then run_dev
        when "new" then run_new
        when "doctor" then run_doctor
        when "help", "-h", "--help" then print_help; 0
        when "--version" then print_version; 0
        else
          @err.puts "grainet: unknown command #{subcommand.inspect}"
          @err.puts
          print_help(io: @err)
          1
        end
      rescue Builder::Error, SFC::ParseError, Scaffold::Error, ConfigLoader::LoadError => e
        @err.puts "grainet: #{e.message}"
        1
      end

      private

      def run_build
        opts = parse_build_opts

        config = Config.load(
          root: opts[:root],
          components_dir: opts[:components],
          pages_dir: opts[:pages],
          output_dir: opts[:output],
          public_dir: opts[:public],
        )

        builder = Builder.new(
          components_dir: config.components_dir,
          pages_dir: config.pages_dir,
          output_dir: config.output_dir,
          public_dir: config.public_dir,
        )
        result = builder.build
        public_suffix = result[:public_files].positive? ? " + #{result[:public_files]} static file(s)" : ""
        @out.puts "Built #{result[:pages]} page(s) from #{result[:components]} component(s)#{public_suffix} → #{relative(config.output_dir)}"
        0
      end

      def run_doctor
        opts = parse_doctor_opts

        config = Config.load(
          root: opts[:root],
          components_dir: opts[:components],
          pages_dir: opts[:pages],
          output_dir: opts[:output],
          public_dir: opts[:public],
        )

        Doctor.new(config, out: @out).run
      end

      def parse_doctor_opts
        opts = {}
        parser = OptionParser.new do |o|
          o.banner = "Usage: grainet doctor [options]"
          add_path_options(o, opts)
          o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
        end
        parser.parse!(@argv)
        opts
      end

      def run_new
        parse_new_opts
        name = @argv.shift

        if name.nil?
          @err.puts "Usage: grainet new <project-name>"
          return 1
        end
        unless @argv.empty?
          @err.puts "grainet new takes exactly one argument; extra: #{@argv.inspect}"
          return 1
        end

        files = Scaffold.new(name).run
        print_creation_summary(name, files)
        print_next_steps(name)
        0
      end

      # `grainet new` currently has no flags beyond -h/--help, but the
      # parser is kept here so future flags (e.g. --no-counter,
      # --with-router) slot in symmetrically with `build` / `dev`.
      def parse_new_opts
        parser = OptionParser.new do |o|
          o.banner = "Usage: grainet new <project-name>"
          o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
        end
        parser.order!(@argv) # `order!` stops at the first non-option argument
      end

      def print_creation_summary(name, files)
        @out.puts "Created #{name}/ (#{files.length} files):"
        files.each { |f| @out.puts "  #{name}/#{f}" }
      end

      def print_next_steps(name)
        @out.puts
        @out.puts "Next steps:"
        @out.puts "  cd #{name}"
        @out.puts "  bundle install"
        @out.puts
        @out.puts "  # 1. Install the mruby-wasm runtime (one-time, ~5MB):"
        @out.puts "  mkdir -p public/vendor/mruby-wasm-js"
        @out.puts "  cp /path/to/mruby-wasm-runtime/build/mruby-js-grainet-full.wasm \\"
        @out.puts "     public/vendor/mruby-js-grainet-full.wasm"
        @out.puts "  cp -r /path/to/mruby-wasm-runtime/mrbgem/mruby-wasm-js/js/* \\"
        @out.puts "        public/vendor/mruby-wasm-js/"
        @out.puts
        @out.puts "  # 2. Verify the setup:"
        @out.puts "  bundle exec grainet doctor"
        @out.puts
        @out.puts "  # 3. Start the dev server (live reload at http://localhost:5173):"
        @out.puts "  bundle exec grainet dev"
      end

      def run_dev
        opts = parse_dev_opts

        config = Config.load(
          root: opts[:root],
          components_dir: opts[:components],
          pages_dir: opts[:pages],
          output_dir: opts[:output],
          public_dir: opts[:public],
          dev_host: opts[:host],
          dev_port: opts[:port],
        )

        server = DevServer.new(
          config,
          host: config.dev_host,
          port: config.dev_port,
          out: @out,
          err: @err,
        )
        server.start
        0
      end

      def parse_dev_opts
        opts = {}
        parser = OptionParser.new do |o|
          o.banner = "Usage: grainet dev [options]"
          o.on("--host HOST", "Bind host (default: #{Config::DEFAULT_DEV_HOST})") { |v| opts[:host] = v }
          o.on("--port PORT", Integer, "Bind port (default: #{Config::DEFAULT_DEV_PORT})") { |v| opts[:port] = v }
          add_path_options(o, opts)
          o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
        end
        parser.parse!(@argv)
        opts
      end

      def parse_build_opts
        opts = {}
        parser = OptionParser.new do |o|
          o.banner = "Usage: grainet build [options]"
          add_path_options(o, opts)
          o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
        end
        parser.parse!(@argv)
        opts
      end

      # The path-config flags `build` / `dev` / `doctor` all accept.
      # `o.on` mutates the OptionParser passed in; `opts` collects the
      # parsed values for the caller's later Config.load merge.
      def add_path_options(o, opts)
        o.on("--components DIR", "Components directory (default: components)") { |v| opts[:components] = v }
        o.on("--pages DIR", "Pages directory (default: pages)") { |v| opts[:pages] = v }
        o.on("--public DIR", "Static-passthrough directory (default: public)") { |v| opts[:public] = v }
        o.on("--output DIR", "-o DIR", "Output directory (default: dist)") { |v| opts[:output] = v }
        o.on("--root DIR", "Project root (default: cwd)") { |v| opts[:root] = v }
      end

      def print_help(io: @out)
        io.puts <<~HELP
          grainet — build .gnt single-file components into static HTML

          Usage:
            grainet <command> [options]

          Commands:
            new <name>  Scaffold a new Grainet app
            build       Compile components/ + pages/ into dist/
            dev         Build, serve, watch — live reload on changes
            doctor      Verify project setup (runtime, references, paths)
            help        Show this help
            --version   Print version

          Tip: place the mruby-wasm runtime under public/vendor/. Run
          `grainet doctor` to check the setup.

          Run `grainet <command> --help` for command-specific options.
        HELP
      end

      def print_version
        @out.puts "grainet-cli #{VERSION}"
      end

      def relative(path)
        Pathname.new(path).relative_path_from(Pathname.new(Dir.pwd)).to_s
      rescue ArgumentError
        path
      end
    end
  end
end
