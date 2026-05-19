# frozen_string_literal: true

require "wsv"
require_relative "builder"
require_relative "build_error"
require_relative "live_reload"
require_relative "watcher"

module Lilac
  module CLI
    # Long-running dev server: initial build, file watch, live reload.
    #
    #   1. Builds `components/*.lil + pages/*.html` → `output_dir/` once,
    #      with the live-reload client script injected
    #   2. Wraps `Wsv::Server` with a custom app that routes
    #      `/__lilac/livereload` to the SSE pub/sub, everything else
    #      to the default static-file `Wsv::App`
    #   3. Starts the file watcher; on debounced change events,
    #      rebuilds and notifies all SSE subscribers, which reload
    #      their pages
    class DevServer
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 5173

      def initialize(config, host: DEFAULT_HOST, port: DEFAULT_PORT, out: $stdout, err: $stderr)
        @config = config
        @host = host
        @port = port
        @out = out
        @err = err
        @live_reload = LiveReload.new
      end

      def start
        rebuild!
        # Watch public/ too, so changes to vendored assets (vendor/*.js,
        # favicons, images) also trigger a rebuild + reload.
        @watcher = Watcher.new(watched_paths) { rebuild_and_notify }
        @watcher.start

        @server = build_server
        @out.puts banner
        @server.start
      ensure
        @watcher&.stop
      end

      def stop
        @server&.stop
        @watcher&.stop
      end

      private

      def rebuild!
        Builder.new(
          components_dir: @config.components_dir,
          pages_dir: @config.pages_dir,
          output_dir: @config.output_dir,
          public_dir: @config.public_dir,
          live_reload: true,
          codegen: @config.codegen,
          # `dev_target` (not `build_target`) is intentional — `lilac dev`
          # follows the dev path: `:full` skips mrbc for fast reloads,
          # `:compiled` exercises the production mrbc + lilac-compiled
          # flow under live reload so the dev experience matches what
          # ships in prod.
          target: @config.dev_target,
          mrbc_path: @config.mrbc_path,
        ).build
      end

      def watched_paths
        [@config.components_dir, @config.pages_dir, @config.public_dir].select { |p| File.directory?(p) }
      end

      def rebuild_and_notify
        @out.puts "lilac dev: rebuilding…"
        rebuild!
        @live_reload.notify_all
        @out.puts "lilac dev: reloaded #{@live_reload.subscriber_count} client(s)"
      rescue Builder::Error, SFC::ParseError, BuildError => e
        # BuildError covers BytecodeBuilder::Error (mrbc invocation
        # failures) as well as Codegen / Compat errors. Keeps the dev
        # loop alive — the watcher stays armed for the next save.
        @err.puts "lilac dev: build failed: #{e.message}"
      end

      def build_server
        Wsv::Server.new(
          host: @host,
          port: @port,
          root: @config.output_dir,
          out: @out,
          err: @err,
          app: build_app,
        )
      end

      # The custom app routes the SSE endpoint to LiveReload; every
      # other URL falls through to the default static-file app rooted
      # at `output_dir/`.
      #
      # `Wsv::App.new` does NOT realpath its root the way `Wsv::Server`
      # does, so we resolve symlinks here. On macOS, `/tmp` is a symlink
      # to `/private/tmp`; without this the resolver's within-root check
      # rejects every request as 403.
      def build_app
        RoutingApp.new(
          default_app: Wsv::App.new(File.realpath(@config.output_dir)),
          live_reload: @live_reload,
          endpoint: LiveReload::ENDPOINT_PATH,
        )
      end

      def banner
        "lilac dev: serving #{@config.output_dir} at http://#{@host}:#{@port}"
      end

      # Wsv app that routes one path to `live_reload`, everything else
      # to `default_app`. Lives here because it's only useful as the
      # dev server's request demultiplexer.
      class RoutingApp
        def initialize(default_app:, live_reload:, endpoint:)
          @default_app = default_app
          @live_reload = live_reload
          @endpoint = endpoint
        end

        def call(request)
          path, = request.target.split("?", 2)
          if path == @endpoint
            @live_reload.call(request)
          else
            @default_app.call(request)
          end
        end
      end
    end
  end
end
