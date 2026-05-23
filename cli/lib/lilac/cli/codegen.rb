# frozen_string_literal: true

require "set"
require_relative "build_error"
require_relative "component_name"
require_relative "../directives" # Lilac::Directives::* (Value / Grammar / ClassParser / Compat)

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

      # Plug-in emitter registry. Each entry: kind (Symbol) → callable
      # `(codegen, directive, context) -> Array<String> | nil`. Built-in
      # `emit_*` methods are tried first via the `case` in
      # `emit_directive`; extensions handle any kind not matched there.
      EMITTERS = {}

      class << self
        def register_emitter(kind, &emitter)
          raise ArgumentError, "block required" unless emitter
          EMITTERS[kind] = emitter
        end

        def emitter_for(kind)
          EMITTERS[kind]
        end

        # Register a named-directive emitter from a `PluginDirectiveSpec`.
        # Generated code shape:
        #   `Foo.hook_name(scanner, raw_value, ref.to_js, item)`
        # where `scanner` is the lazy `Lilac::Component#scanner` accessor
        # (one Scanner per component-mount, shared across hook calls).
        def register_named_directive_emitter(spec)
          register_emitter(spec.kind) do |codegen, directive, context|
            codegen.send(:emit_named_directive, spec, directive, context)
          end
        end
      end

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
      #
      # `emit_include:` controls the trailing `<Class>.include(Lilac::
      # Bindings::<Class>)` line. The default (`true`) is what the
      # `:full` target wants — the include lets the override apply even
      # when the codegen output is the only consumer of the Bindings
      # module. The `:compiled` target sets `false` and relies on the
      # framework's `Component#lookup_codegen_bindings` to dispatch by
      # name, because for compiled output the module-definition tag
      # arrives AFTER `Lilac.start` (which runs mid-script) and an
      # explicit include line would either run too late OR refer to a
      # not-yet-defined class.
      def self.generate(component_name:, directives:, source_path: nil, emit_include: true)
        new(
          component_name: component_name,
          directives: directives,
          source_path: source_path,
          emit_include: emit_include,
        ).run
      end

      # Public for extension emitters that need to format source-location
      # comments / errors in the same `<file>:<line>` shape as built-in
      # emitters do.
      attr_reader :file

      # Public helper for extension emitters: parse a directive's value
      # as a Lilac::Directives::Value (Ivar or BareIdent) or raise with a
      # source-location-tagged error. Same shape as the internal helper
      # used by built-in emitters.
      def read_value_or_raise(directive, attr_name)
        value = Lilac::Directives::Value.parse(directive.value)
        return value if value

        raise Error.new(
          "Invalid value for #{attr_name}: #{directive.value.inspect} " \
          "(expected `@ivar` or bare identifier)",
          at: directive.source_location(@file),
        )
      end

      def initialize(component_name:, directives:, source_path:, emit_include: true)
        @component_name = ComponentName.new(component_name)
        @directives = directives
        @file = source_path ? File.basename(source_path) : "(template)"
        @emit_include = emit_include
      end

      def run
        return "" if @directives.empty?

        # Composition + applicability checks. Run before key_map so
        # composition violations are reported with their own messages
        # rather than getting masked by a downstream parse/emit error.
        Lilac::Directives::Compat.check!(@directives, file: @file)

        # data-key directives are paired with their data-each by
        # ref_id; build the lookup once so emit_each doesn't have to
        # re-scan. Also surfaces "data-key without data-each" /
        # "invalid data-key value" build errors early.
        @key_map = build_key_map

        by_scope = @directives.group_by(&:scope_id)

        # `@inner_scope_set` lets emit_each decide whether to emit the
        # `bind_template_hook__each_N(it, t)` call inside its bind_list
        # block. When the iteration body has zero directives (e.g. the
        # only thing inside data-each is a nested data-component whose
        # body is handled by that component's own AST), the per-each
        # method isn't generated and calling it would NoMethodError at
        # mount.
        @inner_scope_set = by_scope.keys.compact.to_set
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

        include_line = @emit_include ? "#{ruby_class}.include(#{module_path})\n" : ""

        <<~RUBY
          #{open_module(module_path)}
          #{indent(method_bodies.join("\n\n"), 2)}
          #{close_module(module_path)}
          #{include_line}
        RUBY
      end

      private

      def build_scope_body(directives_in_scope, context)
        directives_in_scope.flat_map { |d| emit_directive(d, context) }.compact
      end

      def emit_directive(directive, context)
        if (ext = Codegen.emitter_for(directive.kind))
          return Array(ext.call(self, directive, context))
        end
        case directive.kind
        when :component
          emit_component(directive)
        when :text
          emit_text(directive, context)
        when :unsafe_html
          emit_unsafe_html(directive, context)
        when :bind
          emit_bind(directive, context)
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

      # Emit code for a directive registered via the convention API
      # (`Scanner.register_named_directive`). Emits a direct call to
      # `<handler>.hook_<name>` so both paths converge on the same
      # method. Value validation lives in the hook body — any
      # `raise Lilac::Error` there surfaces at mount time via
      # `Lilac.logger.error` (mirroring built-in directive behaviour).
      def emit_named_directive(spec, directive, context)
        raw = directive.value.to_s
        ref_expr = "#{context.refs_expr}.#{directive.ref_id}.to_js"
        item_expr = context.in_iteration ? "it" : "nil"
        [
          "# #{@file}:#{directive.line} — data-#{spec.name}=#{raw.inspect}",
          "#{spec.handler_constant}.#{spec.method_name}(scanner, #{raw.inspect}, #{ref_expr}, #{item_expr})",
        ]
      end

      # data-text="@s" → `bind refs.lilN, text: @s`. Value must be
      # ivar or bare ident (read-only); arbitrary expressions are rejected
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

      # data-bind="@s" → `bind_input refs.lilN, @s, property: :value`
      # (or :checked for checkbox inputs). Form-independent two-way
      # binding: the value must be `@ivar` or bare identifier (inside
      # data-each); both must resolve at runtime to a writable Signal.
      # See directive-spec §6.2 for the full grammar and form-scope
      # collision rule.
      def emit_bind(directive, context)
        value = read_bind_value_or_raise(directive)
        property = bind_property_or_raise(directive)
        [
          "# #{@file}:#{directive.line} — data-bind=#{value.inspect}",
          "bind_input #{context.refs_expr}.#{directive.ref_id}, #{value.signal_ref}, property: :#{property}",
        ]
      end

      # data-bind value parser. Accepts ivar or bare ident; both must
      # resolve to a writable Signal at runtime.
      def read_bind_value_or_raise(directive)
        value = Lilac::Directives::Value.parse(directive.value)
        return value if value.is_a?(Lilac::Directives::Value::Ivar) || value.is_a?(Lilac::Directives::Value::BareIdent)

        raise Error.new(
          "Invalid value for data-bind: #{directive.value.inspect} " \
          "(expected `@ivar` or bare identifier pointing at a writable Signal)",
          at: directive.source_location(@file),
        )
      end

      # Form-control DOM property selection. Mirrors the runtime
      # detect_bind_property logic; kept here as a build-time precheck
      # so dist HTML breaks loudly rather than silently no-op.
      def bind_property_or_raise(directive)
        tag = directive.element_tag.to_s.downcase
        case tag
        when "input"
          type = (directive.element_attrs || {})["type"].to_s.downcase
          case type
          when "checkbox"        then "checked"
          when "radio"
            raise Error.new(
              "data-bind on <input type=radio> is not supported yet; " \
              "use data-on-change + manual signal update for now",
              at: directive.source_location(@file),
            )
          when "file"
            raise Error.new(
              "data-bind on <input type=file> is not supported (the " \
              "files property is read-only from script); use data-on-change",
              at: directive.source_location(@file),
            )
          else "value"
          end
        when "textarea", "select" then "value"
        else
          raise Error.new(
            "data-bind=#{directive.value.inspect} is only allowed on " \
            "<input> / <textarea> / <select> (got <#{tag}>)",
            at: directive.source_location(@file),
          )
        end
      end

      # data-show / data-hide → toggle the reserved `lil-hidden` class
      # based on the signal. `data-show` adds the class when falsy
      # (show on truthy); `data-hide` adds it when truthy. Always wraps
      # the value in `computed { ... }` so ivar (`@s.value`) and bare
      # ident (item-field lookup) flow through the same shape — the
      # only difference between the two directives is the `!` negation
      # prefix, parameterized as `negation:`.
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

      # Parses the directive's raw value into a `Lilac::Directives::Value` (Ivar
      # or BareIdent), raising a build error on invalid input. Caller
      # uses the returned object's polymorphic `reactive_read` /
      # `bind_source` / `to_s` rather than re-classifying the string.
      # data-on-X="m" → `refs.lilN.on(:X) { |ev| m(ev) }` at the top
      # level, or `t.refs.lilN.on(:X) { |ev| m(it, ev) }` inside a
      # data-each body — iteration handlers receive `(item, event)` so
      # the method can act on the row.
      def emit_on(directive, context)
        method_name = directive.value.to_s.strip
        unless Lilac::Directives::Grammar.method_ident?(method_name)
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
        if Lilac::Directives::Grammar.banned_attr?(name)
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
        unless Lilac::Directives::Grammar.kebab_name?(name)
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
            Lilac::Directives::ClassParser.parse(directive.value)
          rescue Lilac::Directives::ClassParser::Error => e
            raise Error.new(
              "data-class: #{e.message}",
              at: directive.source_location(@file),
            )
          end
        parsed = pairs.map do |key, raw|
          value = Lilac::Directives::Value.parse(raw)
          unless value
            raise Error.new(
              "data-class: invalid value #{raw.inspect} for key #{key.inspect} " \
              "(expected `@ivar` or bare identifier)",
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
            # Mirror runtime scanner's `build_key_proc` exactly: Hash
            # items try Symbol key first, then String key; everything
            # else uses `public_send`. The earlier `->(it) { it.<field> }`
            # form blew up on Hash items with `NoMethodError: undefined
            # method '<field>' for Hash` — and `data-each` over Hash
            # items is the common shape (JSON-decoded data, kanban /
            # receipt examples).
            sym = key_field.to_sym.inspect
            str = key_field.inspect
            "->(it) { it.is_a?(Hash) ? (it.key?(#{sym}) ? it[#{sym}] : it[#{str}]) : it.public_send(#{sym}) }"
          else
            # No data-key specified — fall back to object_id, stable
            # per item for the lifetime of a render cycle.
            "->(it) { it.object_id }"
          end
        tpl_name = @component_name.each_template_name(ref_id)
        # Only call `bind_template_hook__each_N` when there are
        # directives in that iteration scope — otherwise the per-each
        # method isn't generated below, and the call would
        # NoMethodError at mount. Common shape: an `<ul data-each>`
        # whose only child is a nested `<li data-component="row">`
        # placeholder — the parent's iteration body has nothing to
        # wire, and the row's bindings live on the row component
        # itself.
        body_call =
          if @inner_scope_set.include?(ref_id)
            # Iteration scope has its own directives — call the per-each
            # method that the module also emits below.
            "  bind_template_hook__each_#{ref_id}(it, t)"
          else
            # No directives in this iteration scope (e.g. the row is a
            # nested `<X data-component="row">` whose bindings live in
            # that component's own bind_template_hook). `bind_list`
            # still requires a block so the reconciler can mount each
            # cloned row, but the block body is a no-op.
            "  # no iteration-body bindings"
          end
        [
          "# #{@file}:#{directive.line} — data-each=#{collection.inspect}#{key_field ? " data-key=#{key_field.inspect}" : ""}",
          %(bind_list #{context.refs_expr}.#{ref_id}, #{collection.bind_source}, key: #{key_expr}, template: #{tpl_name.inspect} do |it, t|),
          body_call,
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
        Lilac::Directives::Grammar.method_ident?(field)
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
