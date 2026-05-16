# frozen_string_literal: true

module Grainet
  module CLI
    # Turns `TemplateAST::Result` (directive list + refs map) into the Ruby
    # source code that mruby-grainet evaluates at component mount.
    #
    # Output convention (chosen in the v0.12 spec implementation plan):
    #
    #   module Grainet::Bindings::Counter
    #     def bind_template_hook
    #       # ... emitted statements, one per directive ...
    #     end
    #   end
    #   Counter.include(Grainet::Bindings::Counter)
    #
    # `bind_template_hook` is called by `Grainet::Component#mount` right
    # after the user's `setup`. A default no-op exists on `Component` so
    # components without any directive compile to nothing at all.
    #
    # Phase A1 scope:
    #
    #   - Only the module/include scaffold is emitted, with an empty
    #     `bind_template_hook` body.
    #   - When the template has zero directives, returns an empty string
    #     so the build output stays untouched (the default no-op on
    #     `Component` handles it).
    #   - Each directive contributes a source-line comment inside the
    #     method body so users can trace generated code back to the
    #     `.gnt` source. The actual codegen for each directive lands in
    #     phases B1+ (per-directive emitters).
    class Codegen
      class << self
        # `component_name` is the kebab-case `.gnt` basename
        # (e.g. "counter", "admin--user-card"). It is converted to the
        # Ruby class path the runtime's autoregister already uses.
        # `directives` is an Array<Directive>; pass `[]` (or omit) for
        # the empty case which returns "" so the build output stays
        # untouched.
        def generate(component_name:, directives:, source_path: nil)
          return "" if directives.empty?

          ruby_class = ruby_class_path(component_name)
          module_path = "Grainet::Bindings::#{ruby_class}"

          <<~RUBY
            #{open_module(module_path)}
            #{indent(method_definition(directives, source_path), 2)}
            #{close_module(module_path)}
            #{ruby_class}.include(#{module_path})
          RUBY
        end

        private

        # "admin--user-card" → "Admin::UserCard". Same convention used by
        # mruby-grainet's autoregister, so the generated `Counter.include(
        # Grainet::Bindings::Counter)` always matches the runtime's
        # resolved class. `--` only between segments — leading / trailing
        # `--` or `-` raise ArgumentError so misnamed files fail loudly
        # rather than emitting `::Foo` / `Foo::`.
        def ruby_class_path(name)
          name.to_s.split("--", -1).map { |segment|
            raise ArgumentError, "Invalid component name: #{name.inspect} (empty namespace segment)" if segment.empty?

            segment.split("-").map { |word|
              raise ArgumentError, "Invalid component name: #{name.inspect} (empty word segment)" if word.empty?

              word[0].upcase + (word[1..] || "")
            }.join
          }.join("::")
        end

        # `module Foo::Bar` works in mruby + CRuby only if `Foo` is
        # already defined. We emit explicit nesting to be safe:
        #
        #   module Grainet; module Bindings; module Counter
        #     ...
        #   end; end; end
        #
        # Open form is chosen over `module Grainet::Bindings::Counter`
        # because the latter raises `NameError: uninitialized constant`
        # on first build if no other code has touched `Grainet::Bindings`.
        def open_module(module_path)
          parts = module_path.split("::")
          parts.map { |p| "module #{p}" }.join("; ")
        end

        def close_module(module_path)
          parts = module_path.split("::")
          parts.map { "end" }.join("; ")
        end

        def method_definition(directives, source_path)
          file = source_path ? File.basename(source_path) : "(template)"
          body = directives.map { |d| directive_comment(d, file) }.join("\n")

          <<~RUBY.chomp
            def bind_template_hook
            #{indent(body, 2)}
            end
          RUBY
        end

        # Phase A1 placeholder: each directive emits a source-line
        # comment only. Phase B1+ replaces this with real `bind` /
        # `refs.X.on(...)` / `bind_list` calls.
        def directive_comment(directive, file)
          if directive.name
            "# #{file}:#{directive.line} — data-#{directive.kind}-#{directive.name}=#{directive.value.inspect} (ref: #{directive.ref_id})"
          else
            "# #{file}:#{directive.line} — data-#{kind_to_attr(directive.kind)}=#{directive.value.inspect} (ref: #{directive.ref_id})"
          end
        end

        # Inverse of TemplateAST's symbol mapping — used to reconstruct
        # the original `data-*` attribute name in comments.
        # `:class_` carries a trailing underscore; strip it.
        def kind_to_attr(kind)
          name = kind.to_s.chomp("_")
          name.tr("_", "-")
        end

        def indent(text, spaces)
          pad = " " * spaces
          text.each_line.map { |l| l.strip.empty? ? l : "#{pad}#{l}" }.join
        end
      end
    end
  end
end
