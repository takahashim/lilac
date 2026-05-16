# frozen_string_literal: true

require_relative "value_grammar"
require_relative "hash_literal_parser"
require_relative "directive_compatibility"

module Grainet
  module CLI
    # Turns `TemplateAST::Result` (directive list + refs map) into the Ruby
    # source code that mruby-grainet evaluates at component mount.
    #
    # Output convention (chosen in the v0.12 spec implementation plan):
    #
    #   module Grainet::Bindings::Counter
    #     def bind_template_hook
    #       # ... emitted statements for top-level directives ...
    #     end
    #     def bind_template_hook__each_g0(it, t)
    #       # ... emitted statements for directives inside <ul data-each>
    #     end
    #   end
    #   Counter.include(Grainet::Bindings::Counter)
    #
    # `bind_template_hook` is called by `Grainet::Component#mount` right
    # after the user's `setup`. A default no-op exists on `Component` so
    # components without any directive compile to nothing at all.
    #
    # Per-directive emitters (one `emit_*` method per directive kind) live
    # as instance methods so per-`generate`-call session data (component
    # name, source filename, data-key lookup) is held in ivars instead of
    # threaded through every dispatch hop. `Context` then only carries
    # the per-scope axis (top-level vs iteration body).
    class Codegen
      class Error < StandardError; end

      # `refs_expr` is the Ruby expression that resolves to the Refs
      # proxy in the current emit context. `in_iteration` toggles the
      # `(it, ev)` vs `(ev)` event handler arity (spec Section 6.1).
      Context = Struct.new(:refs_expr, :in_iteration, keyword_init: true) do
        def self.top_level
          new(refs_expr: "refs", in_iteration: false)
        end

        def self.iteration
          new(refs_expr: "t.refs", in_iteration: true)
        end
      end

      # `component_name` is the kebab-case `.gnt` basename
      # (e.g. "counter", "admin--user-card"). It is converted to the
      # Ruby class path the runtime's autoregister already uses.
      # `directives` is an Array<Directive>; pass `[]` (or omit) for
      # the empty case which returns "" so the build output stays
      # untouched.
      def self.generate(component_name:, directives:, source_path: nil)
        new(component_name: component_name, directives: directives, source_path: source_path).run
      end

      # Per-component synthetic template name for a data-each body.
      # Kept on the class because Builder calls it externally to render
      # the matching `<template>` tag without re-deriving the convention.
      def self.each_template_name(component_name, ref_id)
        "gn-each-#{component_name}-#{ref_id}"
      end

      def initialize(component_name:, directives:, source_path:)
        @component_name = component_name
        @directives = directives
        @file = source_path ? File.basename(source_path) : "(template)"
      end

      def run
        return "" if @directives.empty?

        # Spec Sections 8 + 9 build-time checks. Run before key_map so
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

        ruby_class = ruby_class_path(@component_name)
        module_path = "Grainet::Bindings::#{ruby_class}"

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

      # data-text="@s" → `bind refs.gN, text: @s`. Value must be
      # ivar or it_path (read-only); arbitrary expressions are rejected
      # at build time per Section 3 of the spec.
      def emit_text(directive, context)
        value = read_value_or_raise(directive, "data-text")
        [
          "# #{@file}:#{directive.line} — data-text=#{value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, text: #{bind_source(value)}",
        ]
      end

      # data-unsafe-html="@s" → `bind refs.gN, html: @s`. Same value
      # shape as data-text. Named "unsafe" so users actively opt in to
      # injecting raw HTML rather than escaped text.
      def emit_unsafe_html(directive, context)
        value = read_value_or_raise(directive, "data-unsafe-html")
        [
          "# #{@file}:#{directive.line} — data-unsafe-html=#{value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, html: #{bind_source(value)}",
        ]
      end

      # data-value="@s" → `bind_input refs.gN, @s`. ivar-only because
      # bind_input writes back to the signal on input events; an
      # immutable iteration item field (`it.x`) couldn't accept the
      # write. Per Section 6.2.
      def emit_value(directive, context)
        value = ivar_or_raise(directive, "data-value")
        [
          "# #{@file}:#{directive.line} — data-value=#{value.inspect}",
          "bind_input #{context.refs_expr}.#{directive.ref_id}, #{value}",
        ]
      end

      # data-checked="@s" → `bind_input refs.gN, @s, property: :checked`.
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

      # data-show / data-hide → toggle the reserved `gn-hidden` class
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
          %(bind #{context.refs_expr}.#{directive.ref_id}, class: { "gn-hidden" => computed { #{negation}#{reactive_read(value)} } }),
        ]
      end

      # Inside `computed { ... }`, signals must be unwrapped via `.value`
      # to subscribe to the dependency; iteration items (`it`,
      # `it.field`) are plain Data attribute access and pass through.
      def reactive_read(value)
        value.start_with?("@") ? "#{value}.value" : value
      end

      # The kwarg form `bind ref, prop: source` calls `source.value`
      # internally — fine for an ivar (a Signal), broken for an
      # it_path (a plain value with no `.value` method). Wrap it_path
      # values in `computed { ... }` so the inner expression yields a
      # Computed whose `.value` returns the field. ivar values pass
      # through verbatim (no double-`.value` wrapping).
      def bind_source(value)
        value.start_with?("@") ? value : "computed { #{value} }"
      end

      def read_value_or_raise(directive, attr_name)
        value = directive.value.to_s.strip
        return value if ValueGrammar.read_value?(value)

        raise Error,
              "Invalid value for #{attr_name} at #{@file}:#{directive.line}: " \
              "#{directive.value.inspect} (expected `@ivar` or `it.path`)"
      end

      def ivar_or_raise(directive, attr_name)
        value = directive.value.to_s.strip
        return value if ValueGrammar.ivar?(value)

        raise Error,
              "Invalid value for #{attr_name} at #{@file}:#{directive.line}: " \
              "#{directive.value.inspect} (expected `@ivar` — writable signal only)"
      end

      # data-on-X="m" → `refs.gN.on(:X) { |ev| m(ev) }` at the top
      # level, or `t.refs.gN.on(:X) { |ev| m(it, ev) }` inside a
      # data-each body (spec Section 6.1: handlers in iteration scope
      # receive `(item, event)` so the method can act on the row).
      def emit_on(directive, context)
        method_name = directive.value.to_s.strip
        unless ValueGrammar.method_ident?(method_name)
          raise Error,
                "Invalid value for data-on-#{directive.name} at " \
                "#{@file}:#{directive.line}: #{directive.value.inspect} " \
                "(expected a method name; `?` predicate and `!` bang are banned)"
        end

        event_literal = symbolize_event(directive.name)
        args = context.in_iteration ? "it, ev" : "ev"
        [
          "# #{@file}:#{directive.line} — data-on-#{directive.name}=#{method_name.inspect}",
          "#{context.refs_expr}.#{directive.ref_id}.on(#{event_literal}) { |ev| #{method_name}(#{args}) }",
        ]
      end

      # data-attr-X="@s" → `bind refs.gN, attr: { "X" => @s }`. Goes
      # through Bindable#bind_attr (Phase C) which calls `source.value`
      # in an effect, handles nil/false → removeAttribute, and runs
      # URL sanitizer on href/src/action/formaction.
      def emit_attr(directive, context)
        name = directive.name.to_s
        if ValueGrammar.banned_attr?(name)
          raise Error,
                "data-attr-#{name} at #{@file}:#{directive.line} targets a banned " \
                "attribute (on*/srcdoc/style). Use data-on-X for event handlers, " \
                "data-css-X or RefElement#set_style for style."
        end
        value = read_value_or_raise(directive, "data-attr-#{name}")
        [
          "# #{@file}:#{directive.line} — data-attr-#{name}=#{value.inspect}",
          %(bind #{context.refs_expr}.#{directive.ref_id}, attr: { #{name.inspect} => #{bind_source(value)} }),
        ]
      end

      # data-css-X="@s" → `effect { refs.gN.set_style("--X", @s.value) }`.
      # The framework auto-prepends `--`, so users write
      # `data-css-progress` (kebab) and get the CSS variable `--progress`.
      # RefElement#set_style maps nil/false → removeProperty so falsy
      # signal values clear the CSS variable per spec Section 7.
      def emit_css(directive, context)
        name = directive.name.to_s
        unless ValueGrammar.kebab_name?(name)
          raise Error,
                "data-css-#{name} at #{@file}:#{directive.line}: X must be " \
                "kebab-lowercase ([a-z][a-z0-9-]*) and not start with `-`."
        end
        value = read_value_or_raise(directive, "data-css-#{name}")
        [
          "# #{@file}:#{directive.line} — data-css-#{name}=#{value.inspect}",
          %(effect { #{context.refs_expr}.#{directive.ref_id}.set_style("--#{name}", #{reactive_read(value)}) }),
        ]
      end

      # data-class="{ active: @s, 'btn-primary': @p }" →
      #   `bind refs.gN, class: { "active" => @s, "btn-primary" => @p }`.
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
            raise Error,
                  "data-class at #{@file}:#{directive.line}: #{e.message}"
          end
        pairs.each do |key, value|
          next if ValueGrammar.read_value?(value)

          raise Error,
                "data-class at #{@file}:#{directive.line}: invalid value " \
                "#{value.inspect} for key #{key.inspect} (expected `@ivar` or `it.path`)"
        end
        body = pairs.map { |k, v| "#{k.inspect} => #{bind_source(v)}" }.join(", ")
        [
          "# #{@file}:#{directive.line} — data-class=#{directive.value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, class: { #{body} }",
        ]
      end

      # data-each="@col" + (optional) data-key="id" →
      #   bind_list refs.gN, @col, key: ->(it) { it.id },
      #             template: "gn-each-<component>-gN" do |it, t|
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
            # Spec Section 6.3: fallback to object_id (Phase H will
            # surface a lint warning). object_id is stable per item
            # for the lifetime of a render cycle.
            "->(it) { it.object_id }"
          end
        tpl_name = self.class.each_template_name(@component_name, ref_id)
        [
          "# #{@file}:#{directive.line} — data-each=#{collection.inspect}#{key_field ? " data-key=#{key_field.inspect}" : ""}",
          %(bind_list #{context.refs_expr}.#{ref_id}, #{collection}, key: #{key_expr}, template: #{tpl_name.inspect} do |it, t|),
          %(  bind_template_hook__each_#{ref_id}(it, t)),
          "end",
        ]
      end

      # Walks the directive list once and returns `{ ref_id => "id" }`
      # for every valid `:key`. Raises if a data-key has no matching
      # data-each on the same element, or if the value violates spec
      # Section 6.3 (must be a bare ident, no `?` / `@` / `it.` / `.`).
      def build_key_map
        each_ref_ids = @directives.select { |d| d.kind == :each }.map(&:ref_id)
        map = {}
        @directives.each do |d|
          next unless d.kind == :key

          unless each_ref_ids.include?(d.ref_id)
            raise Error,
                  "data-key at #{@file}:#{d.line} must be on the same element as data-each. " \
                  "Move it to the data-each element."
          end
          field = d.value.to_s.strip
          unless valid_key_field?(field)
            raise Error,
                  "data-key at #{@file}:#{d.line}: #{d.value.inspect} is not a bare field name. " \
                  "Use `data-key=\"id\"` (no `it.` prefix, no `@`, no `.`, no `?`)."
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
