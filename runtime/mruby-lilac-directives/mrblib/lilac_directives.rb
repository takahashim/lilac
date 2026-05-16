module Lilac
  module Directives
    # Runtime scanner for declarative `data-*` directives.
    #
    # When a Lilac::Component mounts, its default `bind_template_hook`
    # checks for `Lilac::Directives::Scanner` and runs it against the
    # component's root subtree. The scanner walks the DOM, parses
    # directive attributes (`data-text`, `data-on-*`, `data-each`, etc.),
    # and calls the same `bind` / `bind_input` / `bind_list` DSL that
    # CLI-emitted code would call.
    #
    # If a `Lilac::Bindings::<ClassName>` module is included into the
    # component class (as CLI codegen produces), its `bind_template_hook`
    # override runs instead — the runtime scanner is the fallback for
    # components built without the CLI.
    #
    # Phase 0: Scanner is a no-op stub. Real dispatch is filled in
    # across Phases 1–3 (see docs/plan).
    class Scanner
      def initialize(host)
        @host = host
      end

      def scan_and_bind
        # No-op until Phase 1.
      end
    end
  end
end
