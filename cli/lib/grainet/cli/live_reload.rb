# frozen_string_literal: true

require "wsv"

module Grainet
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
      ENDPOINT_PATH = "/__grainet/livereload"

      # `:keepalive` is a SSE-comment frame: clients ignore it, but
      # writing it lets us detect a dropped connection (the write raises
      # Errno::EPIPE) when no real reload event has fired in a while.
      KEEPALIVE_INTERVAL = 30

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

      def subscriber_count
        @mutex.synchronize { @subscribers.length }
      end

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
          if msg.nil?
            io.write(":keepalive\n\n")
          else
            io.write("data: #{msg}\n\n")
          end
          io.flush
        end
      end
    end
  end
end
