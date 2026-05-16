# frozen_string_literal: true

require_relative "value_grammar"

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
    # Implements per-directive emitters (one `emit_*` method per
    # directive kind). Directive kinds without a real emitter fall back
    # to a placeholder comment, so adding a new directive is purely
    # additive: write `emit_<kind>` and add its dispatch in
    # `emit_directive`. Phase progress is tracked in the implementation
    # plan rather than mirrored here.
    class Codegen
      class Error < StandardError; end

      class << self
        # `component_name` is the kebab-case `.gnt` basename
        # (e.g. "counter", "admin--user-card"). It is converted to the
        # Ruby class path the runtime's autoregister already uses.
        # `directives` is an Array<Directive>; pass `[]` (or omit) for
        # the empty case which returns "" so the build output stays
        # untouched.
        def generate(component_name:, directives:, source_path: nil)
          return "" if directives.empty?

          file = source_path ? File.basename(source_path) : "(template)"
          body_lines = directives.flat_map { |d| emit_directive(d, file) }.compact

          # All directives may be no-ops (e.g. only `data-component`
          # markers on the template). In that case skip the module / include
          # to keep the build output minimal.
          return "" if body_lines.empty?

          ruby_class = ruby_class_path(component_name)
          module_path = "Grainet::Bindings::#{ruby_class}"

          <<~RUBY
            #{open_module(module_path)}
            #{indent(method_definition(body_lines), 2)}
            #{close_module(module_path)}
            #{ruby_class}.include(#{module_path})
          RUBY
        end

        private

        def emit_directive(directive, file)
          case directive.kind
          when :component
            emit_component(directive)
          when :text
            emit_text(directive, file)
          when :unsafe_html
            emit_unsafe_html(directive, file)
          when :value
            emit_value(directive, file)
          when :checked
            emit_checked(directive, file)
          when :show
            emit_show(directive, file)
          when :hide
            emit_hide(directive, file)
          when :on
            emit_on(directive, file)
          else
            # Fallback for directives not yet implemented in later
            # phases (data-each / data-key / data-class / data-attr-X /
            # data-arg-X / data-css-X). Emits a placeholder comment so
            # the build doesn't choke; the real emitter replaces it.
            [directive_comment(directive, file)]
          end
        end

        # data-component is consumed by the runtime's autoregister via
        # MutationObserver — the codegen has nothing to emit. Returning
        # `nil` lets `flat_map.compact` drop it cleanly.
        def emit_component(_directive)
          nil
        end

        # data-text="@s" → `bind refs.gN, text: @s`. Value must be
        # ivar or it_path (read-only); arbitrary expressions are rejected
        # at build time per Section 3 of the spec.
        def emit_text(directive, file)
          value = read_value_or_raise(directive, file, "data-text")
          [
            "# #{file}:#{directive.line} — data-text=#{value.inspect}",
            "bind refs.#{directive.ref_id}, text: #{value}",
          ]
        end

        # data-unsafe-html="@s" → `bind refs.gN, html: @s`. Same value
        # shape as data-text. Named "unsafe" so users actively opt in to
        # injecting raw HTML rather than escaped text.
        def emit_unsafe_html(directive, file)
          value = read_value_or_raise(directive, file, "data-unsafe-html")
          [
            "# #{file}:#{directive.line} — data-unsafe-html=#{value.inspect}",
            "bind refs.#{directive.ref_id}, html: #{value}",
          ]
        end

        # data-value="@s" → `bind_input refs.gN, @s`. ivar-only because
        # bind_input writes back to the signal on input events; an
        # immutable iteration item field (`it.x`) couldn't accept the
        # write. Per Section 6.2.
        def emit_value(directive, file)
          value = ivar_or_raise(directive, file, "data-value")
          [
            "# #{file}:#{directive.line} — data-value=#{value.inspect}",
            "bind_input refs.#{directive.ref_id}, #{value}",
          ]
        end

        # data-checked="@s" → `bind_input refs.gN, @s, property: :checked`.
        # Same ivar-only constraint as data-value; the difference is the
        # DOM property targeted (checkbox / radio `checked` instead of
        # input `value`).
        def emit_checked(directive, file)
          value = ivar_or_raise(directive, file, "data-checked")
          [
            "# #{file}:#{directive.line} — data-checked=#{value.inspect}",
            "bind_input refs.#{directive.ref_id}, #{value}, property: :checked",
          ]
        end

        # data-show / data-hide → toggle the reserved `gn-hidden` class
        # based on the signal. `data-show` adds the class when falsy
        # (show on truthy); `data-hide` adds it when truthy. Always wraps
        # the value in `computed { ... }` so ivar (`@s.value`) and
        # it_path (`it.x` — Data attribute access) flow through the same
        # shape — the only difference between the two directives is the
        # `!` negation prefix, parameterized as `negation:`.
        def emit_show(directive, file)
          emit_visibility(directive, file, "data-show", negation: "!")
        end

        def emit_hide(directive, file)
          emit_visibility(directive, file, "data-hide", negation: "")
        end

        def emit_visibility(directive, file, attr_name, negation:)
          value = read_value_or_raise(directive, file, attr_name)
          [
            "# #{file}:#{directive.line} — #{attr_name}=#{value.inspect}",
            %(bind refs.#{directive.ref_id}, class: { "gn-hidden" => computed { #{negation}#{reactive_read(value)} } }),
          ]
        end

        # Inside `computed { ... }`, signals must be unwrapped via `.value`
        # to subscribe to the dependency; iteration items (`it`,
        # `it.field`) are plain Data attribute access and pass through.
        def reactive_read(value)
          value.start_with?("@") ? "#{value}.value" : value
        end

        def read_value_or_raise(directive, file, attr_name)
          value = directive.value.to_s.strip
          return value if ValueGrammar.read_value?(value)

          raise Error,
                "Invalid value for #{attr_name} at #{file}:#{directive.line}: " \
                "#{directive.value.inspect} (expected `@ivar` or `it.path`)"
        end

        def ivar_or_raise(directive, file, attr_name)
          value = directive.value.to_s.strip
          return value if ValueGrammar.ivar?(value)

          raise Error,
                "Invalid value for #{attr_name} at #{file}:#{directive.line}: " \
                "#{directive.value.inspect} (expected `@ivar` — writable signal only)"
        end

        # data-on-X="m" → `refs.gN.on(:X) { |ev| m(ev) }`. Method name
        # must be a plain identifier — no `?` predicate suffix (would
        # confuse event handlers with read-only queries) and no `!`
        # (bang banned for all directives).
        def emit_on(directive, file)
          method_name = directive.value.to_s.strip
          unless ValueGrammar.method_ident?(method_name)
            raise Error,
                  "Invalid value for data-on-#{directive.name} at " \
                  "#{file}:#{directive.line}: #{directive.value.inspect} " \
                  "(expected a method name; `?` predicate and `!` bang are banned)"
          end

          event_literal = symbolize_event(directive.name)
          [
            "# #{file}:#{directive.line} — data-on-#{directive.name}=#{method_name.inspect}",
            "refs.#{directive.ref_id}.on(#{event_literal}) { |ev| #{method_name}(ev) }",
          ]
        end

        # Custom DOM events can have hyphens (`card-deleted`); keep them
        # as quoted symbol literals so the Ruby parser accepts the name
        # verbatim. Plain identifiers compile to `:click` form for
        # readability.
        def symbolize_event(name)
          if /\A[a-zA-Z_][a-zA-Z0-9_]*\z/.match?(name)
            ":#{name}"
          else
            %(:"#{name}")
          end
        end

        # Phase B1+ fallback for directives without a real emitter yet.
        # Will disappear once every directive has a per-kind emit_*.
        def directive_comment(directive, file)
          if directive.name
            "# #{file}:#{directive.line} — data-#{kind_to_attr(directive.kind)}-#{directive.name}=#{directive.value.inspect} (ref: #{directive.ref_id})"
          else
            "# #{file}:#{directive.line} — data-#{kind_to_attr(directive.kind)}=#{directive.value.inspect} (ref: #{directive.ref_id})"
          end
        end

        # `:class_` carries a trailing underscore so it doesn't collide
        # with Ruby's reserved `class` in pattern contexts; strip it.
        def kind_to_attr(kind)
          kind.to_s.chomp("_").tr("_", "-")
        end

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

        # Open form is chosen over `module Grainet::Bindings::Counter`
        # because the latter raises `NameError: uninitialized constant`
        # on first build if no other code has touched `Grainet::Bindings`.
        def open_module(module_path)
          module_path.split("::").map { |p| "module #{p}" }.join("; ")
        end

        def close_module(module_path)
          module_path.split("::").map { "end" }.join("; ")
        end

        def method_definition(body_lines)
          body = body_lines.join("\n")
          <<~RUBY.chomp
            def bind_template_hook
            #{indent(body, 2)}
            end
          RUBY
        end

        def indent(text, spaces)
          pad = " " * spaces
          text.each_line.map { |l| l.strip.empty? ? l : "#{pad}#{l}" }.join
        end
      end
    end
  end
end
