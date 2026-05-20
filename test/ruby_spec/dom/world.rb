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
      attr_reader :document

      def initialize(host)
        @host = host
        @document = Document.new(host)
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
        when "console"      then :console     # handled by Symbol sentinel
        when "Object"       then :object_ctor # likewise
        when "Array"        then :array_ctor
        when "JSON"         then :json_ctor
        else nil
        end
      end

      def __js_set__(key, value)
        # `JS.global[:x] = ...` from wasm. No persistence needed for
        # foundation; future sessions may add localStorage etc.
        nil
      end

      def __js_call__(method, args)
        # No window-level methods supported yet. setTimeout / etc come
        # in session 5 (scheduler).
        nil
      end
    end
  end
end
