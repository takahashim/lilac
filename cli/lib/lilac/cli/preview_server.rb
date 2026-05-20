# frozen_string_literal: true

require "wsv"

module Lilac
  module CLI
    # Static server for the `lilac build` output. The intent is "ship-
    # parity preview": serve `dist/` as a CDN / static host would, with
    # no file watcher, no live reload, no rebuild. Use this to verify
    # the production-mode (default `--target compiled`) output before
    # deploy.
    #
    # Mirrors `vite preview` semantics: separate command, separate
    # default port from `lilac dev`, no automation.
    class PreviewServer
      class Error < BuildError; end

      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 4173

      def initialize(output_dir, host: DEFAULT_HOST, port: DEFAULT_PORT, out: $stdout, err: $stderr)
        @output_dir = output_dir
        @host = host
        @port = port
        @out = out
        @err = err
      end

      def start
        verify_dist!
        @server = build_server
        @out.puts banner
        @server.start
      end

      def stop
        @server&.stop
      end

      private

      def verify_dist!
        unless File.directory?(@output_dir)
          raise Error,
                "lilac preview: output directory #{@output_dir.inspect} does not exist. " \
                "Run `lilac build` first."
        end
        return if Dir.glob(File.join(@output_dir, "*.html")).any?
        raise Error,
              "lilac preview: no HTML files under #{@output_dir.inspect}. " \
              "Run `lilac build` first."
      end

      def build_server
        Wsv::Server.new(
          host: @host,
          port: @port,
          root: @output_dir,
          out: @out,
          err: @err,
          app: Wsv::App.new(File.realpath(@output_dir)),
        )
      end

      def banner
        "lilac preview: serving #{@output_dir} at http://#{@host}:#{@port}"
      end
    end
  end
end
