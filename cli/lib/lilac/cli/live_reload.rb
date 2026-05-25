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

      # Client snippet injected by the builder into every dev-server page.
      # Subscribes to the dev server's SSE channel and handles two event
      # types:
      #
      #   - default `message` event → successful rebuild, reload the page
      #     (any in-page error overlay is implicitly discarded by the
      #     reload, no explicit cleanup needed)
      #   - `error` event → build failed; render an in-page overlay with
      #     the error type + message so the dev sees the failure without
      #     switching to the terminal
      #
      # The overlay is intentionally inline-styled and self-contained
      # (`__lilac_err_overlay`), no dependency on user styles.
      SCRIPT = <<~HTML
        <script>
          // lilac dev: live reload + error overlay via SSE
          (function () {
            const ES_URL = "/__lilac/livereload";
            const OVERLAY_ID = "__lilac_err_overlay";

            function renderOverlay(payload) {
              document.getElementById(OVERLAY_ID)?.remove();
              const root = document.createElement("div");
              root.id = OVERLAY_ID;
              root.setAttribute("style", [
                "position:fixed", "inset:0", "z-index:2147483647",
                "background:rgba(0,0,0,0.78)", "color:#fff",
                "font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace",
                "padding:32px", "overflow:auto",
              ].join(";"));

              const panel = document.createElement("div");
              panel.setAttribute("style", [
                "max-width:880px", "margin:0 auto",
                "background:#1f1f23", "border:1px solid #ff5b6c",
                "border-radius:8px", "padding:20px 24px",
                "box-shadow:0 12px 40px rgba(0,0,0,0.45)",
              ].join(";"));

              const head = document.createElement("div");
              head.setAttribute("style", "display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px");
              const title = document.createElement("strong");
              title.textContent = "lilac dev: build failed";
              title.setAttribute("style", "color:#ff5b6c;font-size:15px");
              const close = document.createElement("button");
              close.type = "button";
              close.textContent = "×";
              close.setAttribute("aria-label", "Dismiss");
              close.setAttribute("style", "background:transparent;border:0;color:#fff;font-size:22px;cursor:pointer;line-height:1");
              close.addEventListener("click", () => root.remove());
              head.appendChild(title);
              head.appendChild(close);
              panel.appendChild(head);

              if (payload && payload.type) {
                const t = document.createElement("div");
                t.textContent = payload.type;
                t.setAttribute("style", "color:#9aa0a6;font-size:12px;margin-bottom:8px");
                panel.appendChild(t);
              }

              const msg = document.createElement("pre");
              msg.textContent = (payload && payload.message) || "(no message)";
              msg.setAttribute("style", "white-space:pre-wrap;word-break:break-word;margin:0;color:#f5f5f5");
              panel.appendChild(msg);

              const hint = document.createElement("div");
              hint.textContent = "Save the file to retry — this overlay will close automatically on a successful rebuild.";
              hint.setAttribute("style", "color:#9aa0a6;font-size:12px;margin-top:14px");
              panel.appendChild(hint);

              root.appendChild(panel);
              document.body.appendChild(root);
            }

            const es = new EventSource(ES_URL);
            es.addEventListener("message", () => location.reload());
            es.addEventListener("error", (ev) => {
              // EventSource fires "error" on transport failure too — those
              // have no `data` field. Distinguish from server-sent error
              // events by presence of `ev.data`.
              if (!ev.data) return;
              try {
                renderOverlay(JSON.parse(ev.data));
              } catch (_e) {
                renderOverlay({ type: "(parse failure)", message: ev.data });
              }
            });
          })();
        </script>
      HTML

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
