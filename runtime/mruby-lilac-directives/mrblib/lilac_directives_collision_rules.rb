module Lilac
  module Directives
    # Collision rules SSOT — duplicate pair (build-time / runtime).
    # See decisions §17.
    #
    # The data here is consumed by both halves of `Lints`:
    #   - build-time: `Lilac::Directives::Lints.check!` (raises)
    #   - runtime:    `Lilac::Directives::Lints.check!` (warn+skip /
    #                 raise depending on severity)
    #
    # Each row in COLLISION_PAIRS is `[attrs, message]` where `attrs`
    # is the unordered pair of `data-*` attribute names that may not
    # coexist on the same element, and `message` is the human-readable
    # rationale used in both build-error and runtime warning text.
    # Attribute-name form (not Symbol kinds) lets the same rules apply
    # uniformly to built-in directives and class-based Handler packages
    # (ADR-0027) — the public surface a user actually writes is the
    # attribute name, so matching against it removes the Symbol-pivot
    # indirection on both sides.
    module Lints
      COLLISION_PAIRS = [
        [
          %w[data-text data-unsafe-html],
          "data-text and data-unsafe-html cannot coexist (both write the element body)",
        ],
        [
          %w[data-text data-each],
          "data-text and data-each cannot coexist (data-each generates children; data-text would overwrite them)",
        ],
        [
          %w[data-unsafe-html data-each],
          "data-unsafe-html and data-each cannot coexist (data-each generates children; data-unsafe-html would overwrite them)",
        ],
        [
          %w[data-show data-hide],
          "data-show and data-hide cannot coexist (use one; the inverse is implicit)",
        ],
        [
          %w[data-component data-each],
          "data-component and data-each cannot coexist (wrap with another element — put the child component inside the iteration body)",
        ],
        [
          %w[data-bind data-field],
          "data-bind and data-field cannot coexist (both wire the input value — pick one: data-bind for form-independent binding, data-field for form-scope binding)",
        ],
      ].freeze
    end
  end
end
