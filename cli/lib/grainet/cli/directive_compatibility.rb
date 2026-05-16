# frozen_string_literal: true

require_relative "build_error"
require_relative "hash_literal_parser"

module Grainet
  module CLI
    # Build-time validation of directive composition rules. Called by
    # Codegen.run after directive collection but before code emission so
    # violations surface as a build error rather than a runtime failure
    # on the user's page.
    #
    # Currently checks pair collisions, tag-level applicability, and
    # `<input>` type-attribute constraints. Not yet enforced:
    #   - data-arg-X validations — data-arg has no emitter yet
    module DirectiveCompatibility
      class Error < BuildError; end

      # Directive pairs that may not coexist on the same element. Each
      # row is [Array<kind>, message].
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
          %i[show hide],
          "data-show and data-hide cannot coexist (use one; the inverse is implicit)",
        ],
        [
          %i[value checked],
          "data-value and data-checked cannot coexist (form control has a single primary state)",
        ],
        [
          %i[component each],
          "data-component and data-each cannot coexist (wrap with another element — put the child component inside the iteration body)",
        ],
      ].freeze

      # Tag-level applicability for data-value / data-checked. The
      # input `type` attribute is further constrained by the two type
      # sets below.
      VALUE_ELEMENTS   = %w[input textarea select].freeze
      CHECKED_ELEMENTS = %w[input].freeze

      # `<input>` types that hold a typing-style value compatible with
      # `data-value` (two-way `value` property binding). HTML defaults
      # an `<input>` without an explicit type to `text`. Excluded:
      # `checkbox`/`radio` (use data-checked) and `file`/`submit`/
      # `button`/`reset`/`image` (no meaningful two-way value binding).
      INPUT_TYPES_FOR_VALUE = %w[
        text email url password search tel
        number date datetime-local month week time
        color range hidden
      ].freeze

      INPUT_TYPES_FOR_CHECKED = %w[checkbox radio].freeze

      def self.check!(directives, file:)
        directives.group_by(&:ref_id).each_value do |dirs_on_element|
          check_collisions(dirs_on_element, file)
          check_gn_hidden_conflict(dirs_on_element, file)
        end
        directives.each { |d| check_element_type(d, file) }
      end

      def self.check_collisions(dirs, file)
        kinds = dirs.map(&:kind).uniq
        COLLISION_PAIRS.each do |pair, message|
          next unless pair.all? { |k| kinds.include?(k) }

          # Report at the line of the second (later) directive in the
          # pair so users see where the conflict was introduced.
          offenders = dirs.select { |d| pair.include?(d.kind) }
          raise Error.new(
            "Directive collision: #{message}",
            file: file, line: offenders.last.line,
          )
        end
      end

      def self.check_element_type(directive, file)
        case directive.kind
        when :value
          check_value_target(directive, file)
        when :checked
          check_checked_target(directive, file)
        end
      end

      def self.check_value_target(directive, file)
        tag = directive.element_tag
        if tag == "input"
          type = input_type(directive)
          return if INPUT_TYPES_FOR_VALUE.include?(type)

          raise Error.new(
            "data-value: <input type=\"#{type}\"> is not a text-style input — " \
            "use data-checked for checkbox/radio.",
            file: file, line: directive.line,
          )
        end
        return if VALUE_ELEMENTS.include?(tag)

        raise Error.new(
          "data-value: only valid on <input>, <textarea>, or <select> — " \
          "found on <#{tag}>",
          file: file, line: directive.line,
        )
      end

      def self.check_checked_target(directive, file)
        tag = directive.element_tag
        if tag == "input"
          type = input_type(directive)
          return if INPUT_TYPES_FOR_CHECKED.include?(type)

          raise Error.new(
            "data-checked: <input type=\"#{type}\"> is not a checkbox or radio — " \
            "use data-value for text-style inputs.",
            file: file, line: directive.line,
          )
        end

        raise Error.new(
          "data-checked: only valid on <input type=\"checkbox\"> or " \
          "<input type=\"radio\"> — found on <#{tag}>",
          file: file, line: directive.line,
        )
      end

      # HTML default for `<input>` with no type attribute is "text".
      def self.input_type(directive)
        attrs = directive.element_attrs || {}
        (attrs["type"] || "text").downcase
      end

      # `gn-hidden` is reserved by data-show / data-hide. If the user
      # puts `'gn-hidden': @x` in data-class on the same element, three
      # signals can race over the class — fail at build time and tell
      # the user to drop the data-class entry.
      #
      # Note: re-parses the data-class hash literal even though
      # `Codegen#emit_class` will parse it again moments later. The
      # double work is intentional — compatibility checks must stay
      # decoupled from codegen so they can run independently (e.g. a
      # future `--lint-only` flag, or surfacing all violations in one
      # pass instead of stopping at the first emit failure). The
      # substring guard above keeps the cost zero for the common case
      # (no `gn-hidden` anywhere in the value).
      def self.check_gn_hidden_conflict(dirs, file)
        return unless dirs.any? { |d| %i[show hide].include?(d.kind) }

        class_dir = dirs.find { |d| d.kind == :class_ }
        return unless class_dir
        return unless class_dir.value.to_s.include?("gn-hidden")

        pairs =
          begin
            HashLiteralParser.parse(class_dir.value)
          rescue HashLiteralParser::Error
            # Malformed data-class — let emit_class raise the parse
            # error with its own location-tagged message instead.
            return
          end
        return unless pairs.any? { |key, _| key == "gn-hidden" }

        raise Error.new(
          "data-class uses the reserved class `gn-hidden` on an element " \
          "that also has data-show / data-hide.",
          file: file, line: class_dir.line,
          suggestion: "Drop the `gn-hidden` key from data-class — data-show/data-hide manage it.",
        )
      end
    end
  end
end
