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
    module Parser
      def self.fragment(html)
        Nokogiri::HTML5.fragment(html.to_s, max_errors: 0)
      end
    end
  end
end
