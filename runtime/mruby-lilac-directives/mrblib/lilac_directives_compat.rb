module Lilac
  module Directives
    # Runtime compat checks. Mirrors `Lilac::CLI::DirectiveCompatibility`
    # but with the runtime severity policy: ergonomics violations are
    # warn+skip, correctness/security violations raise.
    #
    # Called by Scanner once per element, after directive extraction
    # but before dispatch. Returns the set of directive kinds to skip
    # (after warning). May raise `Lilac::Error` on hard violations.
    module Compat
      class << self

      # `directives` is Array<[kind, name, value]>. `tag_name` is the
      # element tag (lowercased). `attrs` is a Hash of element
      # attributes (lowercase keys, string values). Returns Set of
      # kinds to skip; may raise Lilac::Error.
      def check!(directives, tag_name:, attrs:, element_descriptor:)
        kinds = directives.map { |k, _, _| k }
        skip = []

        # Hard collisions (correctness) — raise.
        check_collision!(kinds, :text, :each, element_descriptor)
        check_collision!(kinds, :text, :unsafe_html, element_descriptor)
        check_collision!(kinds, :unsafe_html, :each, element_descriptor)
        check_collision!(kinds, :show, :hide, element_descriptor)
        check_collision!(kinds, :component, :each, element_descriptor)

        # data-key without data-each — warn + skip the orphan key.
        if kinds.include?(:key) && !kinds.include?(:each)
          warn_skip("data-key", tag_name, element_descriptor,
                    "is only meaningful when paired with data-each on the same element")
          skip << :key
        end

        skip
      end

      def check_collision!(kinds, a, b, element_descriptor)
        return unless kinds.include?(a) && kinds.include?(b)
        raise Lilac::Error,
              "directive collision: data-#{kind_label(a)} and data-#{kind_label(b)} " \
              "cannot coexist on the same element (#{element_descriptor})"
      end

      def kind_label(kind)
        kind.to_s.chomp("_").tr("_", "-")
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
