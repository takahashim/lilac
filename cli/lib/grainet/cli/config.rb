# frozen_string_literal: true

require_relative "config_loader"

module Grainet
  module CLI
    # Holds resolved paths and server settings for the build pipeline.
    # Three sources, in increasing precedence:
    #
    #   1. Built-in defaults (DEFAULT_* constants below)
    #   2. `grainet.config.rb` at the project root (via ConfigLoader)
    #   3. CLI flags (`--components`, `--port`, etc.)
    #
    # Most call sites should use `Config.load(opts)`, which performs the
    # three-way merge in one shot. `Config.new(...)` remains for tests
    # and callers that want to construct a config without a file.
    class Config
      DEFAULT_COMPONENTS_DIR = "components"
      DEFAULT_PAGES_DIR = "pages"
      DEFAULT_OUTPUT_DIR = "dist"
      # Static files in `public/` are mirrored to `output_dir/` at
      # build time (Vite / Eleventy / Astro convention). The directory
      # itself is optional — Builder skips silently when absent.
      DEFAULT_PUBLIC_DIR = "public"
      DEFAULT_DEV_HOST = "127.0.0.1"
      DEFAULT_DEV_PORT = 5173

      attr_reader :root, :components_dir, :pages_dir, :output_dir, :public_dir,
                  :dev_host, :dev_port

      # Three-way merge: CLI opts > grainet.config.rb > built-in defaults.
      # `opts` keys mirror the keyword args of `initialize`; nil values
      # mean "no CLI override given" and let the file/default win.
      def self.load(root: nil, components_dir: nil, pages_dir: nil, output_dir: nil,
                    public_dir: nil, dev_host: nil, dev_port: nil)
        resolved_root = File.expand_path(root || Dir.pwd)
        settings = ConfigLoader.load(resolved_root) || ConfigLoader::Settings.new

        new(
          root: resolved_root,
          components_dir: components_dir || settings.components_dir,
          pages_dir:   pages_dir   || settings.pages_dir,
          output_dir:  output_dir  || settings.output_dir,
          public_dir:  public_dir  || settings.public_dir,
          dev_host:    dev_host    || settings.dev_host,
          dev_port:    dev_port    || settings.dev_port,
        )
      end

      def initialize(root: nil, components_dir: nil, pages_dir: nil, output_dir: nil,
                     public_dir: nil, dev_host: nil, dev_port: nil)
        # Use `|| Dir.pwd` rather than a default keyword so callers can
        # pass `root: opts[:root]` (often nil from un-set CLI flags)
        # without overriding the default to nil.
        @root = File.expand_path(root || Dir.pwd)
        @components_dir = expand(components_dir || DEFAULT_COMPONENTS_DIR)
        @pages_dir = expand(pages_dir || DEFAULT_PAGES_DIR)
        @output_dir = expand(output_dir || DEFAULT_OUTPUT_DIR)
        @public_dir = expand(public_dir || DEFAULT_PUBLIC_DIR)
        @dev_host = dev_host || DEFAULT_DEV_HOST
        @dev_port = dev_port || DEFAULT_DEV_PORT
      end

      private

      def expand(path)
        File.expand_path(path, @root)
      end
    end
  end
end
