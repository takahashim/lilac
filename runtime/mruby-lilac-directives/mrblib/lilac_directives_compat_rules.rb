module Lilac
  module Directives
    # Collision rules SSOT — duplicate pair (build-time / runtime).
    # See decisions §17.
    #
    # The data here is consumed by both halves of `Compat`:
    #   - build-time: `Lilac::Directives::Compat.check!` (raises)
    #   - runtime:    `Lilac::Directives::Compat.check!` (warn+skip /
    #                 raise depending on severity)
    #
    # Each row in COLLISION_PAIRS is `[kinds, message]` where `kinds`
    # is the unordered pair of directive kinds that may not coexist on
    # the same element, and `message` is the human-readable rationale
    # used in both build-error and runtime warning text.
    module Compat
      COLLISION_PAIRS = [
        [
          %i[text unsafe_html],
          "data-text and data-unsafe-html cannot coexist (both write the element body)",
        ],
        [
          %i[text each],
          "data-text and data-each cannot coexist (data-each generates children; data-text would overwrite them)",
        ],
        [
          %i[unsafe_html each],
          "data-unsafe-html and data-each cannot coexist (data-each generates children; data-unsafe-html would overwrite them)",
        ],
        [
          %i[show hide],
          "data-show and data-hide cannot coexist (use one; the inverse is implicit)",
        ],
        [
          %i[component each],
          "data-component and data-each cannot coexist (wrap with another element — put the child component inside the iteration body)",
        ],
        [
          %i[bind field],
          "data-bind and data-field cannot coexist (both wire the input value — pick one: data-bind for form-independent binding, data-field for form-scope binding)",
        ],
      ].freeze
    end
  end
end
