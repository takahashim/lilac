# frozen_string_literal: true

# Build-time-only extension to `Lilac::Directives::Value`. Re-opens
# `Value::Ivar` and `Value::BareIdent` to add the polymorphic codegen
# helpers used by `Lilac::CLI::Codegen` (`reactive_read` /
# `bind_source` / `signal_ref`). The base file `value.rb` is the
# diff-0 duplicate-pair body shared with runtime; this file lives
# only on the build-time side. See decisions §17.

module Lilac
  module Directives
    class Value::Ivar
      # Inside a `computed { ... }` block, `@count` alone won't
      # subscribe — the `.value` call is what registers the read.
      def reactive_read
        "#{@raw}.value"
      end

      # `bind ref, prop: source` calls `source.value` inside its own
      # effect, so the Signal object itself (no `.value`) is what we
      # pass.
      def bind_source
        @raw
      end

      # data-bind: bind_input wants the raw Signal (it owns the
      # subscription side). Same as bind_source for Ivar.
      def signal_ref
        @raw
      end
    end

    class Value::BareIdent
      # Bare ident inside a bind_list block reads the per-row field
      # via `Lilac::ItemField.read(it, :name)` (Hash-aware lookup) so
      # JSON-decoded items work without NoMethodError.
      def reactive_read
        "Lilac::ItemField.read(it, :#{@raw})"
      end

      # Field reads aren't Signals, so wrap in `computed { ... }` to
      # stay reactive across iteration item changes.
      def bind_source
        "computed { #{reactive_read} }"
      end

      # data-bind: the resolved field must itself be a writable Signal
      # for bind_input to wire correctly (asserted at runtime).
      def signal_ref
        reactive_read
      end
    end
  end
end
