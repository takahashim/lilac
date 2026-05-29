# frozen_string_literal: true

module Lilac
  module Directives
    # Build-time validation of directive composition rules. Called after
    # directive collection so violations surface as a build error rather
    # than a runtime failure on the user's page.
    #
    # Duplicate pair (build-time / runtime). See decisions §17. The
    # build-time half raises on every violation; the runtime half
    # (runtime/mruby-lilac-directives/mrblib/lilac_directives_lints.rb)
    # applies warn+skip for ergonomics violations.
    #
    # Currently checks pair collisions, tag-level applicability, and
    # `<input>` type-attribute constraints. Not yet enforced:
    #   - data-arg-X validations — data-arg has no emitter yet
    module Lints
      # `COLLISION_PAIRS` lives in `collision_rules.rb` (the duplicate-
      # pair SSOT). This file consumes it via the constant lookup below.
      class Error < Lilac::CLI::BuildError; end

      def self.check!(directives, file:)
        # Group by (scope_id, ref_id) so directives that share a `lilN`
        # NAME but live in different ref scopes (top-level vs each
        # iteration body) are not falsely flagged as colliding. With
        # the per-scope positional counter (decisions §19), ref_ids are
        # only unique WITHIN a scope.
        directives.group_by { |d| [d.scope_id, d.ref_id] }.each_value do |dirs_on_element|
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
        attr_names = dirs.map { |d| attribute_for(d) }
        COLLISION_PAIRS.each do |pair, message|
          next unless pair.all? { |a| attr_names.include?(a) }

          # Report at the line of the second (later) directive in the
          # pair so users see where the conflict was introduced.
          offenders = dirs.select { |d| pair.include?(attribute_for(d)) }
          raise Error.new(
            "Directive collision: #{message}",
            at: offenders.last.source_location(file),
          )
        end
      end

      # Derive the `data-*` attribute name from a TemplateAST directive.
      # Mirrors the runtime helper of the same name: both built-in
      # directive kinds and CLI-registered emitter kinds (form's
      # `:form` / `:field` / `:button`) follow the `data-<kind>` rule
      # with `_` → `-` and a trailing `_` stripped.
      def self.attribute_for(directive)
        "data-#{directive.kind.to_s.tr('_', '-').chomp('-')}"
      end

      # `lil-hidden` is reserved by data-show / data-hide. If the user
      # puts `'lil-hidden': @x` in data-class on the same element, three
      # signals can race over the class — fail at build time and tell
      # the user to drop the data-class entry.
      #
      # Note: parses the data-class hash literal purely for this check.
      # The substring guard above keeps the cost zero for the common
      # case (no `lil-hidden` anywhere in the value).
      def self.check_gn_hidden_conflict(dirs, file)
        return unless dirs.any? { |d| %i[show hide].include?(d.kind) }

        class_dir = dirs.find { |d| d.kind == :class_ }
        return unless class_dir
        return unless class_dir.value.to_s.include?("lil-hidden")

        pairs =
          begin
            ClassParser.parse(class_dir.value)
          rescue ClassParser::Error
            # Malformed data-class — the runtime scanner surfaces the
            # parse error at mount; skip the conflict check here.
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
