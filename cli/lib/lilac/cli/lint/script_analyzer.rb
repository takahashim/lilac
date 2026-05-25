# frozen_string_literal: true

require "prism"

module Lilac
  module CLI
    # AST-based scanner for the user's `<script type="text/ruby">` body.
    # Walks the prism AST to extract:
    #
    #   - **Signal declarations**: `@x = signal/computed/resource/
    #     persistent_signal(...)` — name + line.
    #   - **Method declarations**: `def name` — name + line.
    #   - **Ivar reads**: every `@x` read (not write). Used by the
    #     dead-code linter so a signal consumed only inside
    #     `computed { ... }` or another method body is correctly
    #     recognised as live.
    #   - **Method calls**: every `name(...)` invocation including
    #     `send(:name)` / `public_send(:name)` / `method(:name)` when
    #     the argument is a symbol literal.
    #
    # Cannot resolve genuinely dynamic dispatch (`send(name)` with
    # variable name, `instance_eval` blocks against external strings,
    # methods added via runtime `include`). Those manifest as
    # occasional false-positive dead-code warnings; users currently
    # have no suppression marker, so the linter trades 95% precision
    # for completeness.
    class ScriptAnalyzer
      SIGNAL_FACTORIES = %w[signal computed resource persistent_signal].freeze

      Result = Struct.new(
        :declared_signals,
        :declared_methods,
        :referenced_ivars,
        :method_calls,
        :assigned_ivars,
        keyword_init: true,
      ) do
        def declares_signal?(name)
          declared_signals.key?(name)
        end

        def declares_method?(name)
          declared_methods.key?(name)
        end

        def references_ivar?(name)
          referenced_ivars.include?(name)
        end

        def calls_method?(name)
          method_calls.include?(name)
        end

        # Soft fallback for the linter's "signal not declared" warning.
        # `@x = make_counter` doesn't put `@x` in `declared_signals`
        # (the RHS isn't a recognised signal factory), but the user
        # has plausibly initialised it via a helper. AST inter-
        # procedural analysis would be needed to be sure, so we
        # silence the warning when any assignment to the ivar exists.
        def assigns_ivar?(name)
          assigned_ivars.include?(name)
        end
      end

      def self.analyze(script_text, class_name: nil)
        parse = Prism.parse(script_text.to_s)
        # `failure?` covers hard syntax errors; on those, hand back a
        # fresh empty result so the linter doesn't fire spurious
        # "undeclared" warnings on top of the user's actual parse
        # error.
        return empty_result if parse.failure?

        # When the caller knows which class the directives belong to,
        # narrow the walk to that class's body. Page-inline scripts
        # carry sibling classes (e.g. `Crud` + `CrudRow`) and otherwise
        # the dead-signal pass would attribute every sibling's signal
        # to the lint target, causing spurious "declared but never
        # read" warnings.
        root_node = parse.value
        if class_name
          scoped = find_class_body(root_node, class_name.to_s)
          # If the class isn't found, fall back to whole-script
          # analysis — it's better to over-include than to silently
          # report empty results.
          root_node = scoped if scoped
        end

        visitor = Visitor.new
        root_node.accept(visitor)
        visitor.to_result
      end

      # DFS for a `class <name>` declaration. Returns the class node's
      # body (so the walker only visits its descendants) or nil when
      # absent. Stops at the first match so nested redefinitions don't
      # silently expand the scope.
      def self.find_class_body(node, target_name)
        return nil unless node.respond_to?(:child_nodes)
        node.child_nodes.each do |child|
          next if child.nil?
          if child.is_a?(Prism::ClassNode) && constant_path_name(child.constant_path) == target_name
            return child.body
          end
          found = find_class_body(child, target_name)
          return found if found
        end
        nil
      end

      # Returns the set of top-level class names declared at the
      # outermost scope of `script_text`. Used by the builder's R4
      # guard (proposal §A.R4) to detect when a page-inline script
      # declares a class whose name collides with a `.lil`-derived
      # component class. On parse failure returns an empty set —
      # ScriptAnalyzer prefers under-reporting over double-error noise
      # when the user already has a syntax error.
      def self.extract_top_level_class_names(script_text)
        parse = Prism.parse(script_text.to_s)
        return [] if parse.failure?

        names = []
        collect_top_level_class_names(parse.value, names)
        names
      end

      def self.collect_top_level_class_names(node, names)
        return unless node.respond_to?(:child_nodes)
        node.child_nodes.each do |child|
          next if child.nil?
          if child.is_a?(Prism::ClassNode)
            n = constant_path_name(child.constant_path)
            names << n if n
            # do NOT recurse: nested classes are scoped to their
            # parent and don't participate in top-level collision
          else
            collect_top_level_class_names(child, names)
          end
        end
      end

      def self.constant_path_name(node)
        return node.name.to_s if node.is_a?(Prism::ConstantReadNode)
        node.slice if node.respond_to?(:slice)
      end

      # Fresh per call — `Struct.new(...).freeze` only freezes the
      # struct, not its Hash/Array contents, so a shared constant
      # would be mutable by any caller that called e.g.
      # `result.referenced_ivars << x` and silently poison every
      # later analyze call.
      def self.empty_result
        Result.new(
          declared_signals: {}, declared_methods: {},
          referenced_ivars: [], method_calls: [], assigned_ivars: [],
        )
      end

      class Visitor < Prism::Visitor
        def initialize
          super
          @declared_signals = {}
          @declared_methods = {}
          @referenced_ivars = []
          @assigned_ivars = []
          @method_calls = []
        end

        def to_result
          Result.new(
            declared_signals: @declared_signals,
            declared_methods: @declared_methods,
            referenced_ivars: @referenced_ivars.uniq,
            method_calls: @method_calls.uniq,
            assigned_ivars: @assigned_ivars.uniq,
          )
        end

        def visit_def_node(node)
          @declared_methods[node.name.to_s] ||= node.location.start_line
          super
        end

        def visit_instance_variable_write_node(node)
          name = node.name.to_s
          @assigned_ivars << name
          if signal_factory_call?(node.value)
            @declared_signals[name] ||= node.location.start_line
          end
          super
        end

        # `@x ||= signal(...)` — operator-write counts as declaration
        # for the same reason as plain `=`. Prism splits this into
        # three node kinds depending on the operator: `+=` etc. use
        # `InstanceVariableOperatorWriteNode`, `||=` uses
        # `InstanceVariableOrWriteNode`, `&&=` uses
        # `InstanceVariableAndWriteNode`.
        def visit_instance_variable_operator_write_node(node)
          record_ivar_op_write(node)
          super
        end

        def visit_instance_variable_or_write_node(node)
          record_ivar_op_write(node)
          super
        end

        def visit_instance_variable_and_write_node(node)
          record_ivar_op_write(node)
          super
        end

        def visit_instance_variable_read_node(node)
          @referenced_ivars << node.name.to_s
          super
        end

        def visit_call_node(node)
          @method_calls << node.name.to_s
          record_metaprogramming_target(node)
          super
        end

        private

        # `send(:foo)` / `public_send(:foo)` / `method(:foo)` with a
        # symbol-literal argument: record the named method as called
        # so dead-method lint doesn't flag a method that's only
        # reached via metaprogramming. User-defined `def method`
        # would shadow `Object#method` here — a minor ambiguity we
        # accept (component code rarely defines a `def method`).
        METAPROGRAMMING_DISPATCH = %w[send public_send method].freeze

        def record_metaprogramming_target(node)
          return unless METAPROGRAMMING_DISPATCH.include?(node.name.to_s)

          first = node.arguments&.arguments&.first
          @method_calls << first.unescaped if first.is_a?(Prism::SymbolNode)
        end

        def record_ivar_op_write(node)
          name = node.name.to_s
          @assigned_ivars << name
          @declared_signals[name] ||= node.location.start_line if signal_factory_call?(node.value)
        end

        def signal_factory_call?(node)
          return false unless node.is_a?(Prism::CallNode)

          SIGNAL_FACTORIES.include?(node.name.to_s)
        end
      end
    end
  end
end
