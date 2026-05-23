module Lilac
  module Directives
    # Validation predicates for `register_named_directive` metadata
    # (`value:` / `allowed_tags:` / `iteration:`). Pure predicate
    # functions — return `nil` on success, an error message `String`
    # on failure. Callers (runtime Scanner / build-time Codegen) raise
    # the appropriate Error subclass with the message.
    #
    # Duplicate pair (build-time / runtime). See decisions §17 + the
    # plug-in proposal in `lilac-proposals.md`. Both halves consume
    # the same `Value` / `Grammar` / `ClassParser` SSOT.
    module Validation
      VALUE_MODES = %i[reactive ident none class_hash custom].freeze
      ITERATION_MODES = %i[both item_only host_only].freeze

      # Check that the raw directive value matches the declared `value:`
      # mode. Returns nil on success, an error message on failure.
      # `:custom` always returns nil — the caller is responsible for
      # invoking the plugin's `validate_<name>` method separately.
      def self.check_value(raw_value, mode)
        case mode
        when :reactive
          return nil if Value.parse(raw_value)
          "expected `@ivar` or bare identifier (got #{raw_value.inspect})"
        when :ident
          s = raw_value.to_s.strip
          return nil if Grammar.method_ident?(s)
          "expected a bare identifier (got #{raw_value.inspect})"
        when :none
          return nil if raw_value.to_s.strip.empty?
          "takes no value (got #{raw_value.inspect})"
        when :class_hash
          begin
            ClassParser.parse(raw_value)
            nil
          rescue ClassParser::Error => e
            e.message
          end
        when :custom
          # Caller invokes plugin's validate_<name> for custom grammar.
          nil
        else
          "unknown value mode #{mode.inspect} (expected one of #{VALUE_MODES.inspect})"
        end
      end

      # Check that the element tag is in the `allowed_tags:` allowlist.
      # `nil` or empty means "any tag is OK".
      def self.check_allowed_tags(tag, allowed_tags)
        return nil if allowed_tags.nil? || allowed_tags.empty?
        tag_str = tag.to_s.downcase
        return nil if allowed_tags.any? { |t| t.to_s.downcase == tag_str }
        "not allowed on <#{tag_str}> (allowed: #{allowed_tags.join(", ")})"
      end

      # Check that the dispatch context (iteration vs host root) is
      # compatible with the directive's `iteration:` declaration.
      # `in_iteration:` is true when the dispatch is inside a data-each
      # row scope.
      def self.check_iteration(in_iteration, mode)
        case mode
        when :both, nil
          nil
        when :item_only
          return nil if in_iteration
          "is only allowed inside data-each scope"
        when :host_only
          return nil unless in_iteration
          "is not allowed inside data-each scope"
        else
          "unknown iteration mode #{mode.inspect} (expected one of #{ITERATION_MODES.inspect})"
        end
      end

      # Name format check for `register_named_directive("foo-bar")`.
      # Allows kebab-case lowercase identifiers (a-z, 0-9, hyphen).
      # Rejects names that start with `data-` (plug-in authors must omit
      # the prefix since the runtime adds it). Used at register time.
      NAME_PATTERN = /\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/

      def self.check_name_format(name)
        name_str = name.to_s
        if name_str.start_with?("data-")
          return "directive name must omit the `data-` prefix " \
                 "(register \"#{name_str.sub(/\Adata-/, "")}\" not \"#{name_str}\")"
        end
        return nil if NAME_PATTERN.match?(name_str)
        "directive name must be kebab-case lowercase " \
          "([a-z][a-z0-9-]*) — got #{name.inspect}"
      end
    end
  end
end
