module Lilac
  module Directives
    # Runtime compat checks.
    #
    # Pairs with cli/lib/lilac/directives/compat.rb but is *not* a
    # diff-0 duplicate — the build-time half raises on every
    # violation, this runtime half applies warn+skip for ergonomics
    # violations and raises only on correctness/security violations.
    # The collision data both halves share lives in `compat_rules.rb`
    # (which IS a diff-0 duplicate). See decisions §17.
    #
    # Called by Scanner once per element, after directive extraction
    # but before dispatch. Returns the set of directive kinds to skip
    # (after warning). May raise `Lilac::Error` on hard violations.
    module Compat
      class << self
        # `directives` is Array<[kind, name, value]>. `tag_name` is the
        # element tag (lowercased). `attrs` is a Hash of element
        # attributes (lowercase keys, string values). Returns Array of
        # kinds to skip; may raise Lilac::Error.
        def check!(directives, tag_name:, attrs:, element_descriptor:)
          kinds = directives.map { |k, _, _| k }
          skip = []

          # Hard collisions (correctness) — raise. COLLISION_PAIRS
          # lives in compat_rules.rb (SSOT shared with build-time).
          COLLISION_PAIRS.each do |pair, message|
            check_collision!(kinds, pair, message, element_descriptor)
          end

          # data-key without data-each — warn + skip the orphan key.
          if kinds.include?(:key) && !kinds.include?(:each)
            warn_skip("data-key", tag_name, element_descriptor,
                      "is only meaningful when paired with data-each on the same element")
            skip << :key
          end

          skip
        end

        def check_collision!(kinds, pair, message, element_descriptor)
          return unless pair.all? { |k| kinds.include?(k) }
          raise Lilac::Error,
                "directive collision: #{message} (#{element_descriptor})"
        end

        def warn_skip(attr, tag, element_descriptor, reason)
          Lilac.logger.warn(
            "#{attr} on <#{tag}> #{reason}; skipping binding (#{element_descriptor})"
          )
        end
      end
    end
  end
end
