# frozen_string_literal: true

require "prism"

module Lilac
  module CLI
    # Build-time scanner for `register_named_directive(...)` declarations
    # in plug-in gems' mrblib. Extracts the directive name + handler
    # module + validation metadata from each call site, returning a list
    # of `PluginDirectiveSpec` records that the builder uses to auto-wire
    # `TemplateAST.register_directive` and `Codegen.register_emitter`.
    #
    # See `docs/lilac-proposals.md` "Directive plug-in 機構" §(b)(l).
    # The scan path is **build_config-driven** (only gems referenced by
    # the active `conf.gem` lines are scanned), and **alphabetical** in
    # both gem order and per-gem mrblib order to keep collision behavior
    # deterministic.
    module PluginScanner
      # One registered directive's specification, extracted from a
      # `register_named_directive("name", handler: Mod)` call.
      PluginDirectiveSpec = Struct.new(
        :name,             # String, e.g. "tooltip"
        :handler_constant, # String constant path, e.g. "Lilac::Extras"
        :source_path,      # absolute mrblib file path (for error messages)
        :source_line,      # line number of the register call
        keyword_init: true,
      ) do
        def kind
          name.to_sym
        end

        # `hook_<snake_name>` method name on handler_constant.
        def method_name
          "hook_#{name.tr("-", "_")}".to_sym
        end
      end

      # Core gems that are not scanned (they don't define plug-in
      # directives via register_named_directive). Anything else under
      # `runtime/mruby-lilac-*` is treated as a candidate plug-in.
      CORE_GEMS = %w[mruby-lilac mruby-lilac-directives].freeze

      # Scan plug-in gems referenced by `build_config_path` and return
      # their `register_named_directive` specs. Returns Array<PluginDirectiveSpec>.
      def self.scan(build_config_path, runtime_root: nil)
        build_config_path = File.expand_path(build_config_path)
        runtime_root ||= File.expand_path(
          File.join(File.dirname(build_config_path), "..", "runtime")
        )

        plugin_gems = extract_plugin_gems(build_config_path)
        plugin_gems.flat_map do |gem_name|
          mrblib_dir = File.join(runtime_root, gem_name, "mrblib")
          next [] unless File.directory?(mrblib_dir)
          Dir.glob(File.join(mrblib_dir, "**", "*.rb")).sort.flat_map do |path|
            scan_file(path)
          end
        end
      end

      # Extract referenced Lilac plug-in gem names from a build_config
      # file (regex-based, ignores `MRuby::CrossBuild` runtime DSL).
      # Returns Array<String> in document order, with CORE_GEMS filtered
      # out and `sort` applied for deterministic processing.
      def self.extract_plugin_gems(build_config_path)
        text = File.read(build_config_path)
        # Capture the basename portion after the last "/" so paths with
        # interpolation (`#{runtime_dir}/mruby-lilac-X`) resolve cleanly.
        names = text.scan(/conf\.gem\s+["'][^"']*\/(mruby-lilac-[a-z0-9_-]+)/)
                    .flatten
                    .uniq
                    .reject { |g| CORE_GEMS.include?(g) }
        names.sort
      end

      # Parse a single mrblib file and extract all
      # `register_named_directive(...)` specs found within. Returns
      # Array<PluginDirectiveSpec>. Files with no matching calls return [].
      def self.scan_file(path)
        result = Prism.parse_file(path)
        return [] if result.failure?

        out = []
        walk(result.value, []) do |call_node, nesting|
          spec = extract_spec(call_node, nesting, path)
          out << spec if spec
        end
        out
      end

      # DFS the AST, tracking the lexical module nesting so `handler:
      # self` calls can resolve to the surrounding `module X ... end`.
      def self.walk(node, nesting, &block)
        return if node.nil?
        if node.is_a?(Prism::ModuleNode)
          name = constant_path_string(node.constant_path)
          new_nesting = nesting + [name]
          walk(node.body, new_nesting, &block) if node.body
          return
        end
        if node.is_a?(Prism::ClassNode)
          name = constant_path_string(node.constant_path)
          new_nesting = nesting + [name]
          walk(node.body, new_nesting, &block) if node.body
          return
        end
        if node.is_a?(Prism::CallNode) && call_targets_register?(node)
          yield node, nesting
        end
        node.compact_child_nodes.each { |c| walk(c, nesting, &block) } if node.respond_to?(:compact_child_nodes)
      end

      # Is this call `Lilac::Directives::Scanner.register_named_directive`?
      def self.call_targets_register?(node)
        return false unless node.name.to_s == "register_named_directive"
        recv = node.receiver
        recv_str = constant_path_string(recv)
        recv_str == "Lilac::Directives::Scanner"
      end

      # Extract spec from a register_named_directive call node.
      # Returns nil if the call doesn't have the required shape (e.g.
      # `handler:` missing, name is not a String literal).
      def self.extract_spec(node, nesting, path)
        args = node.arguments&.arguments || []
        first = args.first
        return nil unless first.is_a?(Prism::StringNode)
        name = first.unescaped

        kwargs = extract_keyword_args(args)
        handler_const = resolve_handler(kwargs["handler"], nesting)
        return nil unless handler_const

        PluginDirectiveSpec.new(
          name: name,
          handler_constant: handler_const,
          source_path: path,
          source_line: node.location.start_line,
        )
      end

      # Collect kwargs from a Prism CallNode argument list into a
      # `{ "key" => literal_value }` hash. Only static literals are
      # resolved (Symbol / String / Array of literals / nil). Dynamic
      # expressions are recorded as the raw AST node so the caller can
      # detect them; we return `nil` for kwargs we can't statically
      # resolve (callers fall back to defaults).
      def self.extract_keyword_args(args)
        kwargs_node = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
        return {} unless kwargs_node

        out = {}
        kwargs_node.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)
          key_node = elem.key
          next unless key_node.is_a?(Prism::SymbolNode)
          out[key_node.unescaped.to_s] = literal_value(elem.value)
        end
        out
      end

      # Resolve a Prism literal node to its Ruby value. Returns the
      # node itself when not a recognised literal (caller can choose
      # how to handle dynamic expressions).
      def self.literal_value(node)
        case node
        when Prism::SymbolNode      then node.unescaped.to_sym
        when Prism::StringNode      then node.unescaped
        when Prism::IntegerNode     then node.value
        when Prism::TrueNode        then true
        when Prism::FalseNode       then false
        when Prism::NilNode         then nil
        when Prism::ArrayNode
          node.elements.map { |e| literal_value(e) }
        when Prism::SelfNode        then :__SELF__
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          # constant path is preserved as a String — callers (e.g.
          # `resolve_handler`) decide what to do
          constant_path_string(node)
        else
          node
        end
      end

      # Convert a Prism::ConstantReadNode / ConstantPathNode tree into
      # its dotted string form (`"Lilac::Extras"`). Returns nil for
      # anything unrecognised.
      def self.constant_path_string(node)
        return nil if node.nil?
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = constant_path_string(node.parent)
          parent ? "#{parent}::#{node.name}" : node.name.to_s
        when Prism::SelfNode
          # surfaced as a string so resolve_handler can distinguish
          ":__SELF__"
        else
          nil
        end
      end

      # Resolve the `handler:` kwarg to a fully-qualified constant-path
      # string. `:__SELF__` means the plugin wrote `handler: self`,
      # which we resolve to the joined lexical nesting
      # (`["Lilac", "Extras"]` → `"Lilac::Extras"`). For the shorthand
      # `module Lilac::Extras` form, nesting already contains the full
      # path so the join is a no-op.
      def self.resolve_handler(handler_value, nesting)
        case handler_value
        when ":__SELF__", :__SELF__
          nesting.empty? ? nil : nesting.join("::")
        when String
          handler_value
        else
          nil
        end
      end
    end
  end
end
