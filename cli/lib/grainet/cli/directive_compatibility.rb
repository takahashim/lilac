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
    # Currently checks pair collisions detectable from the Directive list
    # alone, plus tag-level element-type checks. Not yet enforced:
    #   - data-component + data-each collision — TemplateAST does not
    #     emit :component directives, so it is invisible here
    #   - <input type=text|email|...> vs <input type=checkbox> for
    #     data-value / data-checked — Directive only carries the tag
    #     name, not the type attribute
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
      ].freeze

      # Element tags accepting data-value / data-checked. Tag-level
      # only; the input `type` attribute check (text/email vs
      # checkbox/radio) is not yet enforced because Directive does not
      # carry the full attribute set.
      VALUE_ELEMENTS   = %w[input textarea select].freeze
      CHECKED_ELEMENTS = %w[input].freeze

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
          return if VALUE_ELEMENTS.include?(directive.element_tag)

          raise Error.new(
            "data-value: only valid on <input>, <textarea>, or <select> — " \
            "found on <#{directive.element_tag}>",
            file: file, line: directive.line,
          )
        when :checked
          return if CHECKED_ELEMENTS.include?(directive.element_tag)

          raise Error.new(
            "data-checked: only valid on <input type=\"checkbox\"> or " \
            "<input type=\"radio\"> — found on <#{directive.element_tag}>",
            file: file, line: directive.line,
          )
        end
      end

      # `gn-hidden` is reserved by data-show / data-hide. If the user
      # puts `'gn-hidden': @x` in data-class on the same element, three
      # signals can race over the class — fail at build time and tell
      # the user to drop the data-class entry.
      def self.check_gn_hidden_conflict(dirs, file)
        return unless dirs.any? { |d| %i[show hide].include?(d.kind) }

        class_dir = dirs.find { |d| d.kind == :class_ }
        return unless class_dir
        # Substring guard avoids re-parsing when the class hash doesn't
        # mention `gn-hidden` at all.
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
