# frozen_string_literal: true

require "optparse"
require "stringio"
require "pathname"
require_relative "option_helpers"

module Lilac
  module CLI
    module Subcommand
      # Base for `lilac <subcommand>` handlers. Each subclass:
      #
      #   1. defines `opts_parser(opts)` returning an OptionParser whose
      #      callbacks populate `opts`
      #   2. defines `run` returning the desired process exit status
      #
      # `Command` instantiates the right subclass based on argv[0] and
      # delegates. Exception handling (turning `Builder::Error` etc. into
      # "lilac: <msg>" + status 1) stays in Command's outer rescue so the
      # error surface is uniform across subcommands.
      class Base
        def initialize(argv, out: $stdout, err: $stderr)
          @argv = argv
          @out = out
          @err = err
        end

        def run
          raise NotImplementedError
        end

        # `lilac help <name>` dispatcher uses this to render per-subcommand
        # help. Sink IO so the `-h` callback some `opts_parser` definitions
        # bake in doesn't fire during help rendering.
        def self.help_text
          sink = StringIO.new
          new([], out: sink, err: sink).send(:opts_parser, {}).to_s
        end

        private

        # Default `parse!` (rearranges argv so flags can appear after
        # positionals). Subcommands like `new` that need `order!` (stops
        # at first non-option) override this.
        def parse_opts
          opts = {}
          opts_parser(opts).parse!(@argv)
          opts
        end

        def opts_parser(_opts)
          raise NotImplementedError
        end

        # Path display helper used by subcommands that report output paths
        # in user-facing messages.
        def relative(path)
          Pathname.new(path).relative_path_from(Pathname.new(Dir.pwd)).to_s
        rescue ArgumentError
          path
        end
      end
    end
  end
end
