module Lilac
  module Directives
    # Base class for package-defined directive handlers (ADR-0027).
    #
    # Subclasses declare which `data-*` attribute they match via the
    # `attribute "..."` class macro and implement the binding logic in
    # `def wire(ctx)`. The `ctx` argument is a `Lilac::Directives::Context`
    # that exposes the matched element, resolved value, iteration item,
    # plus high-level helpers (`bind_attribute` / `on` / `after_mount`).
    #
    # Register the class with `Lilac::Directives::Scanner.register("Class::Name")`.
    # The String form (not the class object) is required so registration
    # is independent of load order — the class is resolved + instantiated
    # lazily on the first dispatch.
    #
    # Example:
    #
    #   module Lilac::Extras
    #     class TooltipDirective < Lilac::Directives::Handler
    #       attribute "data-tooltip"
    #
    #       def wire(ctx)
    #         return unless ctx.value
    #         ctx.bind_attribute("title", to: ctx.value)
    #       end
    #     end
    #   end
    #   Lilac::Directives::Scanner.register("Lilac::Extras::TooltipDirective")
    #
    # The 1-arg ctx-based API replaced the 6-arg block API (`register_directive`
    # in §23 / §25) for package authors. See decisions/ADR-0027 for the
    # rationale (Ruby class-first principle, stable Context surface,
    # OOP for complex directives).
    class Handler
      class << self
        # Declare the HTML attribute name this handler matches. Required:
        # every Handler subclass must call this exactly once. String only
        # (exact match) — regex / prefix matching is reserved for built-in
        # directives, not exposed to packages.
        def attribute(name = nil)
          if name.nil?
            @_attribute
          else
            raise ArgumentError,
                  "attribute must be a String literal (got #{name.class}); " \
                  "regex / prefix matching is not part of the package API" \
                  unless name.is_a?(String)
            @_attribute = name.freeze
          end
        end

        # Optional phase ordering. `:pre` runs before `:default`
        # directives on the same element (use sparingly — only when a
        # registration must be visible to other directives in the same
        # subtree, the way form's `:field` is). Most packages need only
        # `:default`.
        def phase(value = nil)
          if value.nil?
            @_phase || :default
          else
            raise ArgumentError,
                  "phase must be :pre or :default (got #{value.inspect})" \
                  unless %i[pre default].include?(value)
            @_phase = value
          end
        end
      end

      # Subclass must override. Invoked once per matched element during
      # the owning component's mount. `ctx` is a `Lilac::Directives::Context`.
      def wire(_ctx)
        raise NotImplementedError,
              "#{self.class.name} must implement #wire(ctx); " \
              "see Lilac::Directives::Handler docstring"
      end
    end
  end
end
