# frozen_string_literal: true

require "listen"

module Lilac
  module CLI
    # Thin wrapper around `listen` that coalesces bursts of file events
    # into a single `on_change` callback. Editors that "save" via
    # write-then-rename or "mtime touch" frequently emit 2–5 events in
    # rapid succession; without debouncing we would rebuild that many
    # times.
    #
    # The implementation timer-resets on each event: after the most
    # recent event, we wait `debounce` seconds of quiet, then fire.
    class Watcher
      DEFAULT_DEBOUNCE = 0.15

      def initialize(paths, debounce: DEFAULT_DEBOUNCE, &on_change)
        raise ArgumentError, "block required" unless on_change

        @paths = paths
        @debounce = debounce
        @on_change = on_change
        @listener = nil
        @pending = nil
        @mutex = Mutex.new
      end

      def start
        # No `only:` filter: callers pass `components/`, `pages/`, and
        # `public/`, and the public mirror needs to react to arbitrary
        # static assets (.js, .css, .wasm, images). Listen's default
        # ignore list already filters .git, swap files, OS metadata.
        @listener = Listen.to(*@paths) do |_modified, _added, _removed|
          schedule_change
        end
        @listener.start
      end

      def stop
        @listener&.stop
        @mutex.synchronize { @pending&.kill }
      end

      private

      def schedule_change
        @mutex.synchronize do
          @pending&.kill
          @pending = Thread.new do
            sleep @debounce
            begin
              @on_change.call
            rescue StandardError => e
              warn "lilac watcher: callback raised #{e.class}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
