# frozen_string_literal: true

require 'fileutils'

require_relative 'build/build_error'
require_relative 'build/bytecode_builder'

module Lilac
  module CLI
    # Compile one or more pure-Ruby package source files (mrblib-style:
    # Handler class definitions plus
    # `Lilac::Directives::Scanner.register("ClassName")` calls) into a
    # single `.mrb` bytecode file that can be loaded into a running
    # `lilac-compiled` VM via `vm.loadBytecode(bytes)`.
    #
    # Wire-level: this is a thin wrapper around `BytecodeBuilder` (which
    # owns mrbc backend discovery + the wasm-driven mrbc fallback). The
    # difference from `build` is that package `.mrb` files have a
    # user-specified output path (no content-hash filename) and are
    # never wrapped with `Lilac.start` / framework boot — they're
    # library-style code that registers directives / defines classes at
    # load time and then yields control back.
    #
    # Multiple inputs are concatenated in the order given, separated by
    # newlines, before compiling. This mirrors how mruby builds gems
    # from their `mrblib/*.rb` set (alphabetical concat → single irep).
    class PackageBuild
      class Error < BuildError; end

      def initialize(inputs:, output:, mrbc_path: nil)
        raise Error, 'package-build: at least one input file required' if inputs.empty?

        @inputs = inputs
        @output = output
        @mrbc_path = mrbc_path
      end

      attr_reader :inputs, :output

      # Compile + write. Returns the absolute output path.
      def run
        source = aggregate_sources
        builder = BytecodeBuilder.new(mrbc_path: @mrbc_path)
        bytecode = builder.compile_to_bytes(source, source_label: source_label)

        FileUtils.mkdir_p(File.dirname(@output))
        File.binwrite(@output, bytecode)
        File.expand_path(@output)
      rescue BytecodeBuilder::Error => e
        raise Error, e.message
      end

      private

      def aggregate_sources
        @inputs.map do |path|
          raise Error, "package-build: input file not found: #{path}" unless File.file?(path)

          File.read(path)
        end.join("\n")
      end

      def source_label
        @inputs.length == 1 ? @inputs.first : "#{@inputs.length} files (#{@inputs.first}, ...)"
      end
    end
  end
end
