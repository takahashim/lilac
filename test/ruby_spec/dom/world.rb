# frozen_string_literal: true

class MrubyWasm
  # DOM polyfill that lets wasmtime-rb drive Lilac's DOM-touching wasm
  # specs without Node + happy-dom. See the master plan at
  # /Users/maki/.claude/plans/polished-beaming-badger.md.
  #
  # Each module under `Dom::*` covers one slice of the browser surface
  # (document tree, events, observers, scheduler, etc.). `MrubyWasm`
  # (in `../mruby_wasm.rb`) dispatches bridge calls to instances of
  # these classes via duck typing — values stored in the handle table
  # respond to `__js_get__` / `__js_set__` / `__js_call__` / `__js_new__`.
  module Dom
    # The browser global. `JS.global` from inside wasm resolves to this.
    # Property access (`JS.global[:document]`, `JS.global[:console]`) is
    # routed through `#__js_get__`. Method calls (`JS.global.call(:foo)`)
    # are routed through `#__js_call__`.
    class Window
      include EventTarget

      attr_reader :document, :scheduler, :location

      def initialize(host)
        @host = host
        @scheduler = Scheduler.new
        @event_ctor = Constructor.new { |args| Event.new(args[0], args[1]) }
        @custom_event_ctor = Constructor.new { |args| CustomEvent.new(args[0], args[1]) }
        @mouse_event_ctor = Constructor.new { |args| MouseEvent.new(args[0], args[1]) }
        @keyboard_event_ctor = Constructor.new { |args| KeyboardEvent.new(args[0], args[1]) }
        @event_target_ctor = Constructor.new { |_args| StandaloneEventTarget.new }
        @error_ctor = Constructor.new { |args| ErrorValue.new(args[0]) }
        @promise_ctor = PromiseConstructor.new(self)
        @mutation_observer_ctor = Constructor.new { |args| MutationObserver.new(self, args[0]) }
        @abort_controller_ctor  = Constructor.new { |_args| AbortController.new }
        @local_storage   = Storage.new
        @session_storage = Storage.new
        @location = Location.new(self)
        @history  = History.new(self, @location)
        @url_ctor = Constructor.new { |args| Url.new(args[0], args[1]) }
        # `JS.global[:__some_key__] = ...` from user code lands here.
        # Lilac specs use this for stub installation (e.g.
        # `__fetchy_stub__`); production code stays on the typed
        # accessors above. We keep it last in the read fallback to
        # avoid shadowing intentional getters.
        @globals = {}
        @document = Document.new(host)
        @document.default_view = self
      end

      # Bridge protocol: respond to a JS-style property read by name.
      # Returns either a Ruby primitive (Integer / String / true / false /
      # nil), a Hash/Array (for JS object/array literals), or a Dom::*
      # instance for live DOM/BOM objects.
      #
      # Anything outside the surface we've explicitly polyfilled returns
      # nil (= JS undefined). Spec failures here are the signal to widen
      # the surface in a future session.
      def __js_get__(key)
        case key
        when "document"     then @document
        when "Event"        then @event_ctor
        when "CustomEvent"  then @custom_event_ctor
        when "MouseEvent"   then @mouse_event_ctor
        when "KeyboardEvent" then @keyboard_event_ctor
        when "EventTarget"  then @event_target_ctor
        when "Error"        then @error_ctor
        when "Promise"      then @promise_ctor
        when "MutationObserver" then @mutation_observer_ctor
        when "AbortController" then @abort_controller_ctor
        when "console"      then :console     # handled by Symbol sentinel
        when "Object"       then :object_ctor # likewise
        when "Array"        then :array_ctor
        when "JSON"         then :json_ctor
        when "performance"  then { "now" => @scheduler.now_ms.to_f }
        when "localStorage" then @local_storage
        when "sessionStorage" then @session_storage
        when "location"     then @location
        when "history"      then @history
        when "URL"          then @url_ctor
        when "fetch"        then FetchFn.new(self)
        else @globals[key]
        end
      end

      def __js_set__(key, value)
        # Stash arbitrary keys for later reads (e.g.
        # `JS.global[:__fetchy_stub__] = map`).
        @globals[key] = value
        # The Fetchy spec's `install_fetch_stub` resets `__fetch_count__`
        # to 0 inside its JS installer (`globalThis.__fetch_count__ = 0;
        # globalThis.fetch = ...`). Our polyfill ignores raw JS, so we
        # piggy-back on the stub assignment to perform the same reset
        # — without it the count accumulates across tests in one VM run.
        @globals["__fetch_count__"] = 0 if %w[__fetchy_stub__ __resource_fetch_stub__ __inject_fetch_stub__].include?(key)
        nil
      end

      attr_reader :globals, :scheduler

      def __js_call__(method, args)
        case method
        when "fetch"
          FetchFn.new(self).__js_call__("call", args)
        when "encodeURIComponent"
          # JS spec encoding: percent-encode anything except
          # `A-Za-z0-9 - _ . ! ~ * ' ( )`. Ruby's `CGI.escape` is close
          # but uses `+` for space, so do it manually for parity.
          require "erb"
          ERB::Util.url_encode(args[0].to_s)
        when "decodeURIComponent"
          require "erb"
          # ERB doesn't provide decode; use CGI for symmetry.
          require "cgi"
          CGI.unescape(args[0].to_s)
        when "addEventListener"
          add_event_listener(args[0], args[1], args[2])
        when "removeEventListener"
          remove_event_listener(args[0], args[1])
        when "dispatchEvent"
          dispatch_event(args[0])
        when "setTimeout"
          @scheduler.set_timeout(args[0], args[1] || 0)
        when "clearTimeout"
          @scheduler.clear_timeout(args[0])
        when "setInterval"
          @scheduler.set_interval(args[0], args[1] || 0)
        when "clearInterval"
          @scheduler.clear_interval(args[0])
        when "requestAnimationFrame"
          @scheduler.request_animation_frame(args[0])
        when "cancelAnimationFrame"
          @scheduler.cancel_animation_frame(args[0])
        when "queueMicrotask"
          @scheduler.queue_microtask(args[0])
        else
          # Additional window-level methods (fetch, location, history,
          # Promise, MutationObserver, etc.) arrive in later sessions.
          nil
        end
      end

      def __event_parent__
        nil
      end

      # Called by History#go and Location.href= to fire popstate /
      # hashchange events. Listeners registered on the Window via
      # `addEventListener("popstate"|"hashchange", cb)` receive them.
      def fire_popstate(state)
        event = CustomEvent.new("popstate", "detail" => state)
        dispatch_event(event)
      end

      def fire_hashchange(old_hash, new_hash)
        event = CustomEvent.new("hashchange", "detail" => { "oldURL" => old_hash, "newURL" => new_hash })
        dispatch_event(event)
      end
    end
  end
end
