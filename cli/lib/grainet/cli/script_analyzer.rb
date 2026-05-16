# frozen_string_literal: true

require "prism"

module Grainet
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

      EMPTY_RESULT = Result.new(
        declared_signals: {}, declared_methods: {},
        referenced_ivars: [], method_calls: [], assigned_ivars: [],
      ).freeze

      def self.analyze(script_text)
        parse = Prism.parse(script_text.to_s)
        # `failure?` covers hard syntax errors; on those, treat as
        # empty so the linter doesn't fire spurious "undeclared"
        # warnings on top of the user's actual parse error.
        return EMPTY_RESULT if parse.failure?

        visitor = Visitor.new
        parse.value.accept(visitor)
        visitor.to_result
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
          method_name = node.name.to_s
          @method_calls << method_name
          # send(:foo) / public_send(:foo) / method(:foo) with a symbol
          # literal argument: record the referenced name so a method
          # called only via metaprogramming isn't flagged dead.
          if %w[send public_send method].include?(method_name)
            first = node.arguments&.arguments&.first
            if first.is_a?(Prism::SymbolNode)
              @method_calls << first.unescaped
            end
          end
          super
        end

        private

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
