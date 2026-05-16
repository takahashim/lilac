# frozen_string_literal: true

require_relative "build_error"
require_relative "component_name"
require_relative "directive_value"
require_relative "value_grammar"
require_relative "hash_literal_parser"
require_relative "directive_compatibility"

module Lilac
  module CLI
    # Turns `TemplateAST::Result` (directive list + refs map) into the Ruby
    # source code that mruby-lilac evaluates at component mount.
    #
    # Output convention (chosen in the v0.12 spec implementation plan):
    #
    #   module Lilac::Bindings::Counter
    #     def bind_template_hook
    #       # ... emitted statements for top-level directives ...
    #     end
    #     def bind_template_hook__each_lil0(it, t)
    #       # ... emitted statements for directives inside <ul data-each>
    #     end
    #   end
    #   Counter.include(Lilac::Bindings::Counter)
    #
    # `bind_template_hook` is called by `Lilac::Component#mount` right
    # after the user's `setup`. A default no-op exists on `Component` so
    # components without any directive compile to nothing at all.
    #
    # Per-directive emitters (one `emit_*` method per directive kind) live
    # as instance methods so per-`generate`-call session data (component
    # name, source filename, data-key lookup) is held in ivars instead of
    # threaded through every dispatch hop. `Context` then only carries
    # the per-scope axis (top-level vs iteration body).
    class Codegen
      class Error < BuildError; end

      # `refs_expr` is the Ruby expression that resolves to the Refs
      # proxy in the current emit context. `in_iteration` toggles the
      # `(it, ev)` vs `(ev)` event handler arity.
      Context = Struct.new(:refs_expr, :in_iteration, keyword_init: true) do
        def self.top_level
          new(refs_expr: "refs", in_iteration: false)
        end

        def self.iteration
          new(refs_expr: "t.refs", in_iteration: true)
        end
      end

      # `component_name` is the kebab-case `.lil` basename
      # (e.g. "counter", "admin--user-card"). It is converted to the
      # Ruby class path the runtime's autoregister already uses.
      # `directives` is an Array<Directive>; pass `[]` (or omit) for
      # the empty case which returns "" so the build output stays
      # untouched.
      def self.generate(component_name:, directives:, source_path: nil)
        new(component_name: component_name, directives: directives, source_path: source_path).run
      end

      def initialize(component_name:, directives:, source_path:)
        @component_name = ComponentName.new(component_name)
        @directives = directives
        @file = source_path ? File.basename(source_path) : "(template)"
      end

      def run
        return "" if @directives.empty?

        # Composition + applicability checks. Run before key_map so
        # composition violations are reported with their own messages
        # rather than getting masked by a downstream parse/emit error.
        DirectiveCompatibility.check!(@directives, file: @file)

        # data-key directives are paired with their data-each by
        # ref_id; build the lookup once so emit_each doesn't have to
        # re-scan. Also surfaces "data-key without data-each" /
        # "invalid data-key value" build errors early.
        @key_map = build_key_map

        by_scope = @directives.group_by(&:scope_id)

        top_body = build_scope_body(by_scope[nil] || [], Context.top_level)
        inner_scopes = by_scope.keys.compact.sort

        # All directives may be no-ops (e.g. only `data-component`
        # markers). Skip the module/include entirely in that case.
        return "" if top_body.empty? && inner_scopes.empty?

        method_bodies = [top_method(top_body)]
        inner_scopes.each do |scope_id|
          body = build_scope_body(by_scope[scope_id] || [], Context.iteration)
          method_bodies << each_method(scope_id, body)
        end

        ruby_class = @component_name.ruby_class
        module_path = "Lilac::Bindings::#{ruby_class}"

        <<~RUBY
          #{open_module(module_path)}
          #{indent(method_bodies.join("\n\n"), 2)}
          #{close_module(module_path)}
          #{ruby_class}.include(#{module_path})
        RUBY
      end

      private

      def build_scope_body(directives_in_scope, context)
        directives_in_scope.flat_map { |d| emit_directive(d, context) }.compact
      end

      def emit_directive(directive, context)
        case directive.kind
        when :component
          emit_component(directive)
        when :text
          emit_text(directive, context)
        when :unsafe_html
          emit_unsafe_html(directive, context)
        when :value
          emit_value(directive, context)
        when :checked
          emit_checked(directive, context)
        when :show
          emit_show(directive, context)
        when :hide
          emit_hide(directive, context)
        when :on
          emit_on(directive, context)
        when :attr
          emit_attr(directive, context)
        when :css
          emit_css(directive, context)
        when :class_
          emit_class(directive, context)
        when :each
          emit_each(directive, context)
        when :key
          # Paired with :each at the same ref_id and consumed by
          # emit_each via @key_map; nothing to emit here.
          nil
        else
          # Fallback for directives not yet implemented in later
          # phases (data-arg-X). Emits a placeholder comment so the
          # build doesn't choke; the real emitter replaces it.
          [directive_comment(directive)]
        end
      end

      # data-component is consumed by the runtime's autoregister via
      # MutationObserver — the codegen has nothing to emit. Returning
      # `nil` lets `flat_map.compact` drop it cleanly.
      def emit_component(_directive)
        nil
      end

      # data-text="@s" → `bind refs.lilN, text: @s`. Value must be
      # ivar or it_path (read-only); arbitrary expressions are rejected
      # at build time.
      def emit_text(directive, context)
        value = read_value_or_raise(directive, "data-text")
        [
          "# #{@file}:#{directive.line} — data-text=#{value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, text: #{value.bind_source}",
        ]
      end

      # data-unsafe-html="@s" → `bind refs.lilN, html: @s`. Same value
      # shape as data-text. Named "unsafe" so users actively opt in to
      # injecting raw HTML rather than escaped text.
      def emit_unsafe_html(directive, context)
        value = read_value_or_raise(directive, "data-unsafe-html")
        [
          "# #{@file}:#{directive.line} — data-unsafe-html=#{value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, html: #{value.bind_source}",
        ]
      end

      # data-value="@s" → `bind_input refs.lilN, @s`. ivar-only because
      # bind_input writes back to the signal on input events; an
      # immutable iteration item field (`it.x`) couldn't accept the
      # write.
      def emit_value(directive, context)
        value = ivar_or_raise(directive, "data-value")
        [
          "# #{@file}:#{directive.line} — data-value=#{value.inspect}",
          "bind_input #{context.refs_expr}.#{directive.ref_id}, #{value}",
        ]
      end

      # data-checked="@s" → `bind_input refs.lilN, @s, property: :checked`.
      # Same ivar-only constraint as data-value; the difference is the
      # DOM property targeted (checkbox / radio `checked` instead of
      # input `value`).
      def emit_checked(directive, context)
        value = ivar_or_raise(directive, "data-checked")
        [
          "# #{@file}:#{directive.line} — data-checked=#{value.inspect}",
          "bind_input #{context.refs_expr}.#{directive.ref_id}, #{value}, property: :checked",
        ]
      end

      # data-show / data-hide → toggle the reserved `lil-hidden` class
      # based on the signal. `data-show` adds the class when falsy
      # (show on truthy); `data-hide` adds it when truthy. Always wraps
      # the value in `computed { ... }` so ivar (`@s.value`) and
      # it_path (`it.x` — Data attribute access) flow through the same
      # shape — the only difference between the two directives is the
      # `!` negation prefix, parameterized as `negation:`.
      def emit_show(directive, context)
        emit_visibility(directive, context, "data-show", negation: "!")
      end

      def emit_hide(directive, context)
        emit_visibility(directive, context, "data-hide", negation: "")
      end

      def emit_visibility(directive, context, attr_name, negation:)
        value = read_value_or_raise(directive, attr_name)
        [
          "# #{@file}:#{directive.line} — #{attr_name}=#{value.inspect}",
          %(bind #{context.refs_expr}.#{directive.ref_id}, class: { "lil-hidden" => computed { #{negation}#{value.reactive_read} } }),
        ]
      end

      # Parses the directive's raw value into a `DirectiveValue` (Ivar
      # or ItPath), raising a build error on invalid input. Caller uses
      # the returned object's polymorphic `reactive_read` / `bind_source`
      # / `to_s` rather than re-classifying the string.
      def read_value_or_raise(directive, attr_name)
        value = DirectiveValue.parse(directive.value)
        return value if value

        raise Error.new(
          "Invalid value for #{attr_name}: #{directive.value.inspect} " \
          "(expected `@ivar` or `it.path`)",
          at: directive.source_location(@file),
        )
      end

      # Like `read_value_or_raise` but rejects it_path — used by
      # `data-value` / `data-checked` which write back to a signal and
      # therefore can't target an immutable iteration item field.
      def ivar_or_raise(directive, attr_name)
        value = DirectiveValue.parse(directive.value)
        return value if value&.ivar?

        raise Error.new(
          "Invalid value for #{attr_name}: #{directive.value.inspect} " \
          "(expected `@ivar` — writable signal only)",
          at: directive.source_location(@file),
        )
      end

      # data-on-X="m" → `refs.lilN.on(:X) { |ev| m(ev) }` at the top
      # level, or `t.refs.lilN.on(:X) { |ev| m(it, ev) }` inside a
      # data-each body — iteration handlers receive `(item, event)` so
      # the method can act on the row.
      def emit_on(directive, context)
        method_name = directive.value.to_s.strip
        unless ValueGrammar.method_ident?(method_name)
          raise Error.new(
            "Invalid value for data-on-#{directive.name}: " \
            "#{directive.value.inspect} (expected a method name; " \
            "`?` predicate and `!` bang are banned)",
            at: directive.source_location(@file),
          )
        end

        event_literal = symbolize_event(directive.name)
        args = context.in_iteration ? "it, ev" : "ev"
        [
          "# #{@file}:#{directive.line} — data-on-#{directive.name}=#{method_name.inspect}",
          "#{context.refs_expr}.#{directive.ref_id}.on(#{event_literal}) { |ev| #{method_name}(#{args}) }",
        ]
      end

      # data-attr-X="@s" → `bind refs.lilN, attr: { "X" => @s }`. Goes
      # through Bindable#bind_attr which calls `source.value` in an
      # effect, handles nil/false → removeAttribute, and runs the URL
      # sanitizer on href/src/action/formaction.
      def emit_attr(directive, context)
        name = directive.name.to_s
        if ValueGrammar.banned_attr?(name)
          raise Error.new(
            "data-attr-#{name} targets a banned attribute (on*/srcdoc/style).",
            at: directive.source_location(@file),
            suggestion: "Use data-on-X for event handlers, data-css-X or RefElement#set_style for style.",
          )
        end
        value = read_value_or_raise(directive, "data-attr-#{name}")
        [
          "# #{@file}:#{directive.line} — data-attr-#{name}=#{value.inspect}",
          %(bind #{context.refs_expr}.#{directive.ref_id}, attr: { #{name.inspect} => #{value.bind_source} }),
        ]
      end

      # data-css-X="@s" → `effect { refs.lilN.set_style("--X", @s.value) }`.
      # The framework auto-prepends `--`, so users write
      # `data-css-progress` (kebab) and get the CSS variable `--progress`.
      # RefElement#set_style maps nil/false → removeProperty so falsy
      # signal values clear the CSS variable.
      def emit_css(directive, context)
        name = directive.name.to_s
        unless ValueGrammar.kebab_name?(name)
          raise Error.new(
            "data-css-#{name}: X must be kebab-lowercase ([a-z][a-z0-9-]*) and not start with `-`.",
            at: directive.source_location(@file),
          )
        end
        value = read_value_or_raise(directive, "data-css-#{name}")
        [
          "# #{@file}:#{directive.line} — data-css-#{name}=#{value.inspect}",
          %(effect { #{context.refs_expr}.#{directive.ref_id}.set_style("--#{name}", #{value.reactive_read}) }),
        ]
      end

      # data-class="{ active: @s, 'btn-primary': @p }" →
      #   `bind refs.lilN, class: { "active" => @s, "btn-primary" => @p }`.
      # Hash keys are normalized to double-quoted strings regardless of
      # the source form (bare ident vs single/double quotes) so the
      # generated Ruby is uniform. Reuses Bindable#bind_class which
      # iterates the mapping in an effect and toggles each class
      # based on signal truthiness.
      def emit_class(directive, context)
        pairs =
          begin
            HashLiteralParser.parse(directive.value)
          rescue HashLiteralParser::Error => e
            raise Error.new(
              "data-class: #{e.message}",
              at: directive.source_location(@file),
            )
          end
        parsed = pairs.map do |key, raw|
          value = DirectiveValue.parse(raw)
          unless value
            raise Error.new(
              "data-class: invalid value #{raw.inspect} for key #{key.inspect} " \
              "(expected `@ivar` or `it.path`)",
              at: directive.source_location(@file),
            )
          end
          [key, value]
        end
        body = parsed.map { |k, v| "#{k.inspect} => #{v.bind_source}" }.join(", ")
        [
          "# #{@file}:#{directive.line} — data-class=#{directive.value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, class: { #{body} }",
        ]
      end

      # data-each="@col" + (optional) data-key="id" →
      #   bind_list refs.lilN, @col, key: ->(it) { it.id },
      #             template: "lil-each-<component>-lilN" do |it, t|
      #     bind_template_hook__each_gN(it, t)
      #   end
      # The body of the iteration becomes a separate method on the
      # generated module (see `each_method`) so nested data-each cleanly
      # shadow `it` / `t` via Ruby's block-param scoping.
      def emit_each(directive, context)
        collection = read_value_or_raise(directive, "data-each")
        ref_id = directive.ref_id
        key_field = @key_map[ref_id]
        key_expr =
          if key_field
            "->(it) { it.#{key_field} }"
          else
            # No data-key specified — fall back to object_id, stable
            # per item for the lifetime of a render cycle.
            "->(it) { it.object_id }"
          end
        tpl_name = @component_name.each_template_name(ref_id)
        [
          "# #{@file}:#{directive.line} — data-each=#{collection.inspect}#{key_field ? " data-key=#{key_field.inspect}" : ""}",
          %(bind_list #{context.refs_expr}.#{ref_id}, #{collection}, key: #{key_expr}, template: #{tpl_name.inspect} do |it, t|),
          %(  bind_template_hook__each_#{ref_id}(it, t)),
          "end",
        ]
      end

      # Walks the directive list once and returns `{ ref_id => "id" }`
      # for every valid `:key`. Raises if a data-key has no matching
      # data-each on the same element, or if the value is not a bare
      # ident (no `?` / `@` / `it.` / `.`).
      def build_key_map
        each_ref_ids = @directives.select { |d| d.kind == :each }.map(&:ref_id)
        map = {}
        @directives.each do |d|
          next unless d.kind == :key

          unless each_ref_ids.include?(d.ref_id)
            raise Error.new(
              "data-key must be on the same element as data-each.",
              at: d.source_location(@file),
              suggestion: "Move it to the data-each element.",
            )
          end
          field = d.value.to_s.strip
          unless valid_key_field?(field)
            raise Error.new(
              "data-key: #{d.value.inspect} is not a bare field name.",
              at: d.source_location(@file),
              suggestion: "Use `data-key=\"id\"` (no `it.` prefix, no `@`, no `.`, no `?`).",
            )
          end
          map[d.ref_id] = field
        end
        map
      end

      def valid_key_field?(field)
        # Reuse method_ident? — same grammar (bare ident, no `?`/`!`).
        ValueGrammar.method_ident?(field)
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

      # Fallback for directives without a real emitter yet (`data-arg-X`
      # waits until full data-each runtime integration in a follow-up).
      def directive_comment(directive)
        if directive.name
          "# #{@file}:#{directive.line} — data-#{kind_to_attr(directive.kind)}-#{directive.name}=#{directive.value.inspect} (ref: #{directive.ref_id})"
        else
          "# #{@file}:#{directive.line} — data-#{kind_to_attr(directive.kind)}=#{directive.value.inspect} (ref: #{directive.ref_id})"
        end
      end

      # `:class_` carries a trailing underscore so it doesn't collide
      # with Ruby's reserved `class` in pattern contexts; strip it.
      def kind_to_attr(kind)
        kind.to_s.chomp("_").tr("_", "-")
      end

      # Open form is chosen over `module Lilac::Bindings::Counter`
      # because the latter raises `NameError: uninitialized constant`
      # on first build if no other code has touched `Lilac::Bindings`.
      def open_module(module_path)
        module_path.split("::").map { |p| "module #{p}" }.join("; ")
      end

      def close_module(module_path)
        module_path.split("::").map { "end" }.join("; ")
      end

      def top_method(body_lines)
        body = body_lines.join("\n")
        <<~RUBY.chomp
          def bind_template_hook
          #{indent(body, 2)}
          end
        RUBY
      end

      def each_method(ref_id, body_lines)
        body = body_lines.join("\n")
        <<~RUBY.chomp
          def bind_template_hook__each_#{ref_id}(it, t)
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
