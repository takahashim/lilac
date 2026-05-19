# frozen_string_literal: true

module Lilac
  module Directives
    # Build-time validation of directive composition rules. Called by
    # Codegen.run after directive collection but before code emission so
    # violations surface as a build error rather than a runtime failure
    # on the user's page.
    #
    # Duplicate pair (build-time / runtime). See decisions §17. The
    # build-time half raises on every violation; the runtime half
    # (runtime/mruby-lilac-directives/mrblib/lilac_directives_compat.rb)
    # applies warn+skip for ergonomics violations.
    #
    # Currently checks pair collisions, tag-level applicability, and
    # `<input>` type-attribute constraints. Not yet enforced:
    #   - data-arg-X validations — data-arg has no emitter yet
    module Compat
      # `COLLISION_PAIRS` lives in `compat_rules.rb` (the duplicate-pair
      # SSOT). This file consumes it via the constant lookup below.
      class Error < Lilac::CLI::BuildError; end

      def self.check!(directives, file:)
        directives.group_by(&:ref_id).each_value do |dirs_on_element|
          check_collisions(dirs_on_element, file)
          check_gn_hidden_conflict(dirs_on_element, file)
        end
        check_form_scope!(directives, file)
      end

      # Scope rules for the form gem (form-spec §8 / §10.2):
      # - `data-form` is only allowed on `<form>` elements
      # - multiple bare `<form>` (no data-form attr) within the same
      #   component would collide on the `:default` scope, so flag the
      #   second occurrence as an error
      def self.check_form_scope!(directives, file)
        seen_default_form = false
        directives.each do |d|
          next unless d.kind == :form

          if d.element_tag != "form"
            raise Error.new(
              "data-form is only allowed on <form> elements " \
              "(found on <#{d.element_tag}>).",
              at: d.source_location(file),
              suggestion: "Move data-form to a <form> element, or drop it if scope isn't needed.",
            )
          end

          # `value == ""` is the synthetic marker injected by TemplateAST
          # for bare <form>. Track the first; flag any second occurrence.
          if d.value.to_s.empty?
            if seen_default_form
              raise Error.new(
                "second bare <form> in the same component would collide on the " \
                ":default scope.",
                at: d.source_location(file),
                suggestion: %(Add `data-form="..."` to one of them to distinguish.),
              )
            end
            seen_default_form = true
          end
        end
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
            at: offenders.last.source_location(file),
          )
        end
      end

      # `lil-hidden` is reserved by data-show / data-hide. If the user
      # puts `'lil-hidden': @x` in data-class on the same element, three
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
      # (no `lil-hidden` anywhere in the value).
      def self.check_gn_hidden_conflict(dirs, file)
        return unless dirs.any? { |d| %i[show hide].include?(d.kind) }

        class_dir = dirs.find { |d| d.kind == :class_ }
        return unless class_dir
        return unless class_dir.value.to_s.include?("lil-hidden")

        pairs =
          begin
            ClassParser.parse(class_dir.value)
          rescue ClassParser::Error
            # Malformed data-class — let emit_class raise the parse
            # error with its own location-tagged message instead.
            return
          end
        return unless pairs.any? { |key, _| key == "lil-hidden" }

        raise Error.new(
          "data-class uses the reserved class `lil-hidden` on an element " \
          "that also has data-show / data-hide.",
          at: class_dir.source_location(file),
          suggestion: "Drop the `lil-hidden` key from data-class — data-show/data-hide manage it.",
        )
      end
    end
  end
end
