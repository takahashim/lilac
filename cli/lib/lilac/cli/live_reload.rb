# frozen_string_literal: true

require "wsv"

module Lilac
  module CLI
    # SSE pub/sub for the dev server's live-reload endpoint.
    #
    # Each connected browser holds an open SSE response served by `#call`.
    # When `notify_all` fires (because the file watcher detected a build),
    # every subscriber receives a "reload" event and refreshes.
    #
    # Subscribers are tracked as `Queue` instances; subscription cleanup
    # happens in an `ensure` so a closed/aborted client doesn't leak.
    class LiveReload
      ENDPOINT_PATH = "/__lilac/livereload"

      # `:keepalive` is a SSE-comment frame: clients ignore it, but
      # writing it lets us detect a dropped connection (the write raises
      # Errno::EPIPE) when no real reload event has fired in a while.
      # Short interval keeps dead subscribers from clogging the wsv
      # connection-throttle pool (default cap 8) on rapid page reloads —
      # without this we'd see 503s after ~8 reloads within 30 s.
      KEEPALIVE_INTERVAL = 5

      def initialize
        @subscribers = []
        @mutex = Mutex.new
      end

      def call(_request)
        queue = subscribe
        Wsv::Response.sse do |io|
          io.write(":connected\n\n")
          io.flush
          serve_loop(queue, io)
        rescue Errno::EPIPE, IOError
          # Client disconnected mid-stream; producer just exits.
        ensure
          unsubscribe(queue)
        end
      end

      def notify_all(message = "reload")
        @mutex.synchronize { @subscribers.each { |q| q << message } }
      end

      # Push a `event: error` SSE frame to all subscribers with the
      # given payload encoded as JSON. The client overlay reads this
      # via `addEventListener("error", ...)` and renders an overlay.
      # A subsequent successful build calls `notify_all("reload")`
      # which reloads the page and the overlay disappears on its own.
      def notify_error(payload)
        require "json"
        json = JSON.generate(payload)
        marker = [ERROR_MARKER, json]
        @mutex.synchronize { @subscribers.each { |q| q << marker } }
      end

      def subscriber_count
        @mutex.synchronize { @subscribers.length }
      end

      # Sentinel object used to tag error tuples in the queue without
      # colliding with any plausible reload-message string.
      ERROR_MARKER = Object.new.freeze

      private

      def subscribe
        queue = Queue.new
        @mutex.synchronize { @subscribers << queue }
        queue
      end

      def unsubscribe(queue)
        @mutex.synchronize { @subscribers.delete(queue) }
      end

      def serve_loop(queue, io)
        loop do
          # Queue#pop(timeout:) is Ruby 3.2+ — required Ruby version
          # already enforced in the gemspec.
          msg = queue.pop(timeout: KEEPALIVE_INTERVAL)
          io.write(format_frame(msg))
          io.flush
        end
      end

      def format_frame(msg)
        case msg
        when nil
          ":keepalive\n\n"
        when Array  # tagged [ERROR_MARKER, json]
          "event: error\ndata: #{msg.last}\n\n"
        else
          "data: #{msg}\n\n"
        end
      end
    end
  end
end
