module Lilac
  module Directives
    # Runtime directive lints.
    #
    # Pairs with cli/lib/lilac/directives/lints.rb but is *not* a
    # diff-0 duplicate — the build-time half raises on every
    # violation, this runtime half applies warn+skip for ergonomics
    # violations and raises only on correctness/security violations.
    # The collision data both halves share lives in `collision_rules.rb`
    # (which IS a diff-0 duplicate). See decisions §17.
    #
    # Called by Scanner once per element, after directive extraction
    # but before dispatch. Returns the set of directive kinds to skip
    # (after warning). May raise `Lilac::Error` on hard violations.
    module Lints
      class << self
        # `directives` is Array<[kind, name, value]>. `tag_name` is the
        # element tag (lowercased). `attrs` is a Hash of element
        # attributes (lowercase keys, string values). Returns Array of
        # kinds to skip; may raise Lilac::Error.
        def check!(directives, tag_name:, attrs:, element_descriptor:)
          attr_names = directives.map { |kind, payload, _| attribute_for(kind, payload) }
          skip = []

          # Hard collisions (correctness) — raise. COLLISION_PAIRS
          # lives in collision_rules.rb (SSOT shared with build-time)
          # and is expressed in attribute-name strings.
          COLLISION_PAIRS.each do |pair, message|
            next unless pair.all? { |a| attr_names.include?(a) }
            raise Lilac::Error,
                  "directive collision: #{message} (#{element_descriptor})"
          end

          # data-key without data-each — warn + skip the orphan key.
          if attr_names.include?("data-key") && !attr_names.include?("data-each")
            warn_skip("data-key", tag_name, element_descriptor,
                      "is only meaningful when paired with data-each on the same element")
            skip << :key
          end

          skip
        end

        def warn_skip(attr, tag, element_descriptor, reason)
          Lilac.logger.warn(
            "#{attr} on <#{tag}> #{reason}; skipping binding (#{element_descriptor})"
          )
        end

        # Derive the `data-*` attribute name from a directive record.
        # Handler payloads expose `attribute` directly (= the very name
        # the package author declared). Built-in Symbol kinds map to
        # `data-<kind>` with `_` → `-` and a trailing `_` (used to
        # avoid the Ruby `class` keyword for `:class_`) stripped.
        def attribute_for(kind, payload)
          return payload.attribute if kind == :handler
          "data-#{kind.to_s.tr('_', '-').chomp('-')}"
        end
      end
    end
  end
end
