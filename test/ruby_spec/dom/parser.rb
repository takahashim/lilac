# frozen_string_literal: true

require "nokogiri"

class MrubyWasm
  module Dom
    # Thin wrapper around Nokogiri's HTML5 fragment parser. Centralizing
    # the entry point lets us:
    #
    #   - Pin parser options (`max_errors: 0` — silent on malformed
    #     HTML, matching browser behavior)
    #   - Swap implementations later (e.g. if we hit Nokogiri::HTML5
    #     quirks around `<template>` or `<select>` children)
    #
    # Known quirks (verified 2026-05-21):
    #
    #   - `<table>`-only fragments wrap children inside an implicit
    #     `<tbody>`. Tests that rely on `<tr>` being a direct child of
    #     `<table>` will fail.
    #   - `<select>` automatically reparents non-option / optgroup
    #     children outside itself. Lilac specs don't construct such
    #     fragments, but worth noting.
    #
    # Returns a Nokogiri::HTML5::DocumentFragment.
    #
    # The `owner_doc` parameter is critical: when a node parsed via a
    # detached fragment gets `add_child`'d into a Document that owns a
    # different Nokogiri document, libxml2 silently **copies** the node
    # (new object_id) instead of moving it. That breaks identity-
    # dependent caches (`Document#wrap_node`, `@by_key[k][:node]` in
    # Lilac's reconciler). Always pass the destination document so the
    # parsed nodes are born in the right owner.
    module Parser
      def self.fragment(html, owner_doc: nil)
        if owner_doc
          owner_doc.fragment(html.to_s)
        else
          Nokogiri::HTML5.fragment(html.to_s, max_errors: 0)
        end
      end
    end
  end
end
