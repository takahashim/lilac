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
      INPUT_TYPES_FOR_VALUE = %w[
        text email number search tel url password date time
        datetime-local month week color
      ].freeze
      VALUE_ELEMENTS = %w[input textarea select].freeze
      CHECKED_INPUT_TYPES = %w[checkbox radio].freeze

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
        check_collision!(kinds, :value, :checked, element_descriptor)
        check_collision!(kinds, :component, :each, element_descriptor)

        # Element-type ergonomics — warn + skip.
        if kinds.include?(:value)
          unless value_element_ok?(tag_name, attrs)
            warn_skip("data-value", tag_name, element_descriptor,
                      "requires <input type=text/email/...>, <textarea>, or <select>")
            skip << :value
          end
        end

        if kinds.include?(:checked)
          unless checked_input_ok?(tag_name, attrs)
            warn_skip("data-checked", tag_name, element_descriptor,
                      "requires <input type=checkbox|radio>")
            skip << :checked
          end
        end

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

      def value_element_ok?(tag, attrs)
        return false unless VALUE_ELEMENTS.include?(tag)
        return true unless tag == "input"
        type = (attrs["type"] || "text").downcase
        INPUT_TYPES_FOR_VALUE.include?(type)
      end

      def checked_input_ok?(tag, attrs)
        return false unless tag == "input"
        type = (attrs["type"] || "text").downcase
        CHECKED_INPUT_TYPES.include?(type)
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
