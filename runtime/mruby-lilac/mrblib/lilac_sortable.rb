# lilac_sortable.rb — Lilac::Sortable mixins.
#
# Mixins to wire HTML5 drag-and-drop reordering into a Component with
# minimal boilerplate. Two mixins, one per role:
#
#   Lilac::Sortable::Item — the draggable row itself. Include and
#   call `make_sortable` in setup. The component's root gets all five
#   native DnD handlers and dispatches `:sortable_reorder` (bubbling)
#   with detail `{ "src" => ..., "dst" => ..., "pos" => "before"|"after" }`
#   on drop.
#
#   Lilac::Sortable::List — the component that owns the list. Include
#   and call `sortable_target(refs.list, signal, key: "id")` in setup.
#   Listens for `:sortable_reorder` from rows and applies the reorder
#   to the signal; also handles drops in empty list space (below the
#   last row, in the gap between rows) as "append to end".
#
# Pure data operations (`reorder_items`, `move_to_end`, `drop_before?`)
# live on the parent `Lilac::Sortable` module so they're testable
# without needing a Component instance.
#
# CSS classes the Item mixin toggles on the row root:
#   is-dragging  — set on the source row while it's being dragged
#   drop-before  — on the hovered target row when cursor is in upper half
#   drop-after   — on the hovered target row when cursor is in lower half
# Style these in your sheet (`opacity: 0.4`, top-edge shadow, etc.).

module Lilac
  module Sortable
    DEFAULT_EVENT = :sortable_reorder

    # ---- Item mixin (row side) ------------------------------------

    module Item
      # Row-side wiring. The row identity (which the List side uses to
      # match the dropped row against the model) is read via `by:`,
      # whose type chooses the source:
      #
      #   - Symbol — `root.data(by)` (HTML `data-*` attribute; default
      #     `:id` → `data-id`, preserving hand-written-row behaviour).
      #   - Signal / Computed — `by.value` at drag-time.
      #   - Proc — called to produce the value.
      #   - Anything else — treated as a literal value (`to_s`-coerced).
      #
      # Components built from `data-prop-id="it.id"` pass `by: @id` to
      # avoid duplicating `data-attr-data-id` on the row template.
      def make_sortable(by: :id, event: DEFAULT_EVENT)
        reader = build_sortable_id_reader(by)
        reorder_event = event

        root.on(:dragstart) do |ev|
          ev[:dataTransfer].setData("text/plain", reader.call.to_s)
          ev[:dataTransfer][:effectAllowed] = "move"
          root.toggle_class("is-dragging", true)
        end

        root.on(:dragend) do |_ev|
          root.toggle_class("is-dragging", false)
        end

        root.on(:dragover) do |ev|
          ev.preventDefault
          ev[:dataTransfer][:dropEffect] = "move"
          before = Sortable.drop_before?(root, ev)
          root.toggle_class("drop-before", before)
          root.toggle_class("drop-after", !before)
        end

        root.on(:dragleave) do |_ev|
          root.toggle_class("drop-before", false)
          root.toggle_class("drop-after", false)
        end

        root.on(:drop) do |ev|
          ev.preventDefault
          # The List-side `<ul>`-level drop handler is an "off-row"
          # fallback — once a specific row has handled the drop, stop
          # the native event before it bubbles up and triggers
          # append-to-end.
          ev.stopPropagation
          root.toggle_class("drop-before", false)
          root.toggle_class("drop-after", false)
          src_id = ev[:dataTransfer].getData("text/plain").to_s
          dst_id = reader.call.to_s
          pos = Sortable.drop_before?(root, ev) ? "before" : "after"
          root.dispatch(reorder_event,
                        detail: { "src" => src_id, "dst" => dst_id, "pos" => pos },
                        bubbles: true)
        end
      end

      private

      def build_sortable_id_reader(by)
        case by
        when Symbol then -> { root.data(by) }
        when Proc   then by
        else
          # Signal / Computed (anything quack-typed with `.value`) →
          # always read the live current value at drag-time. Bare
          # scalars fall into the same branch and get returned as-is
          # (callers `.to_s` the result before use).
          by.respond_to?(:value) ? -> { by.value } : -> { by }
        end
      end
    end

    # ---- List mixin (host side) -----------------------------------

    module List
      # Host-side wiring. Listens for the reorder event on the list
      # element itself (`el_ref`) — that scopes naturally to row
      # events from this `<ul>` only, so multiple sortable lists
      # inside one component (or nested sortable trees) don't cross-fire.
      # Also adds a fallback drop handler on `el_ref` so cursors
      # released in empty list space (below the last row, in the gap
      # between rows) still append the source instead of being lost.
      #
      # `signal` and `key:` can be omitted when the ref's element carries
      # `data-each="@items" data-key="id"`: the actual wiring is deferred
      # to just after `bind_template_hook`, by which point the directive
      # scanner has recorded `(source, key)` via `register_each_binding`.
      # Pass both explicitly for imperative `bind_list` callers (no
      # scanner registration in that path) — wiring then runs immediately.
      def sortable_target(el_ref, signal = nil, key: nil, event: DEFAULT_EVENT)
        if signal.nil? || key.nil?
          defer_until_bound do
            apply_sortable_target(el_ref, signal, key, event)
          end
        else
          apply_sortable_target(el_ref, signal, key, event)
        end
      end

      private

      def apply_sortable_target(el_ref, signal, key, event)
        el = el_ref.is_a?(RefElement) ? el_ref : wrap(el_ref)
        if signal.nil? || key.nil?
          name = el.respond_to?(:name) ? el.name : nil
          binding = name ? each_binding_for(name) : nil
          if binding
            signal ||= binding[:source]
            key    ||= binding[:key]
          end
        end
        if signal.nil? || key.nil?
          raise Lilac::Error,
                "sortable_target(#{(el.respond_to?(:name) && el.name) || "?"}): " \
                "no `data-each` binding recorded for this ref. Either annotate " \
                "the list element with `data-each=\"@items\" data-key=\"id\"` " \
                "(both attributes required) or pass `signal` + `key:` explicitly."
        end

        el.on(event) do |ev|
          src_id = ev[:detail][:src].to_s
          dst_id = ev[:detail][:dst].to_s
          pos    = ev[:detail][:pos].to_s
          next if src_id == dst_id
          signal.update { |arr| Sortable.reorder_items(arr, key, src_id, dst_id, pos) }
        end

        el.on(:dragover) do |ev|
          ev.preventDefault
          ev[:dataTransfer][:dropEffect] = "move"
        end

        el.on(:drop) do |ev|
          ev.preventDefault
          src_id = ev[:dataTransfer].getData("text/plain").to_s
          next if src_id.empty?
          signal.update { |arr| Sortable.move_to_end(arr, key, src_id) }
        end
      end

    end

    # ---- Pure data ops (exposed for tests) -------------------------

    # Pull src out of arr, then re-insert before / after dst. Comparison
    # is via `.to_s` on both sides so callers can mix String / Integer
    # ids without normalising upstream.
    def self.reorder_items(arr, key, src_id, dst_id, pos)
      src = src_id.to_s
      dst = dst_id.to_s
      item = arr.find { |it| it[key].to_s == src }
      return arr unless item
      filtered = arr.reject { |it| it[key].to_s == src }
      dst_idx = filtered.index { |it| it[key].to_s == dst }
      return arr unless dst_idx
      dst_idx += 1 if pos == "after"
      filtered.insert(dst_idx, item)
    end

    def self.move_to_end(arr, key, src_id)
      src = src_id.to_s
      item = arr.find { |it| it[key].to_s == src }
      return arr unless item
      arr.reject { |it| it[key].to_s == src } + [item]
    end

    def self.drop_before?(root_el, event)
      rect = root_el.to_js.call(:getBoundingClientRect)
      midpoint = (rect[:top].to_f + rect[:bottom].to_f) / 2.0
      event[:clientY].to_f < midpoint
    end
  end
end
