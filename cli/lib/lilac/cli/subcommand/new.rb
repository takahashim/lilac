# frozen_string_literal: true

require_relative "base"
require_relative "../scaffold"

module Lilac
  module CLI
    module Subcommand
      class New < Base
        def run
          parse_opts
          name = @argv.shift

          if name.nil?
            @err.puts "Usage: lilac new <project-name>"
            return 1
          end
          unless @argv.empty?
            @err.puts "lilac new takes exactly one argument; extra: #{@argv.inspect}"
            return 1
          end

          files = Scaffold.new(name).run
          print_creation_summary(name, files)
          print_next_steps(name)
          0
        end

        private

        # `lilac new` currently has no flags beyond -h/--help, but the
        # parser is kept here so future flags (e.g. --no-counter,
        # --with-router) slot in symmetrically with `build` / `dev`.
        # `order!` (not `parse!`) so positional `<project-name>` after
        # `lilac new` doesn't get consumed as a flag value.
        def parse_opts
          opts = {}
          opts_parser(opts).order!(@argv)
          opts
        end

        def opts_parser(_opts = {})
          OptionParser.new do |o|
            o.banner = "Usage: lilac new <project-name>"
            o.on("-h", "--help", "Show help") { @out.puts o; exit 0 }
          end
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
          @out.puts "  # 1. Install the mruby-wasm runtime for `lilac dev` (one-time, ~5MB):"
          @out.puts "  mkdir -p public/vendor/lilac-full/mruby-wasm-js"
          @out.puts "  cp /path/to/lilac/build/lilac-full.wasm \\"
          @out.puts "     public/vendor/lilac-full/lilac-full.wasm"
          @out.puts "  cp -r /path/to/mruby-wasm-runtime/mrbgem/mruby-wasm-js/js/* \\"
          @out.puts "        public/vendor/lilac-full/mruby-wasm-js/"
          @out.puts
          @out.puts "  # 2. Verify the setup:"
          @out.puts "  bundle exec lilac doctor"
          @out.puts
          @out.puts "  # 3. Start the dev server (live reload at http://localhost:5173):"
          @out.puts "  bundle exec lilac dev"
          @out.puts
          @out.puts "  # 4. When ready to ship, `lilac build` produces an optimized"
          @out.puts "  #    --target compiled dist (smaller bundle; requires mrbc"
          @out.puts "  #    discoverable via env / monorepo / npm — see README)."
          @out.puts "  #    For an mrbc-free build, run: lilac build --target full"
        end
      end
    end
  end
end
