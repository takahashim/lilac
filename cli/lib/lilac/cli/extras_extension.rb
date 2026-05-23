# frozen_string_literal: true

require_relative "codegen"
require_relative "template_ast"

# CLI counterpart to runtime/mruby-lilac-extras. Registers build-time
# template-walk recognition and codegen emitters for the extras
# directives. Same shape as `form_extension.rb`.

module Lilac
  module CLI
    module ExtrasExtension
      # data-tooltip="@msg" / "field" → bind title attribute to the value.
      def self.emit_tooltip(codegen, directive, context)
        value = codegen.read_value_or_raise(directive, "data-tooltip")
        [
          "# #{codegen.file}:#{directive.line} — data-tooltip=#{value.inspect}",
          "bind #{context.refs_expr}.#{directive.ref_id}, attr: { \"title\" => #{value.bind_source} }",
        ]
      end

      # data-autofocus — value-less flag directive. Calls .focus on the
      # underlying JS element when the component's hook runs (post-mount).
      def self.emit_autofocus(codegen, directive, context)
        [
          "# #{codegen.file}:#{directive.line} — data-autofocus",
          "#{context.refs_expr}.#{directive.ref_id}.to_js.call(:focus)",
        ]
      end
    end
  end
end

# ---- registrations ---------------------------------------------------

Lilac::CLI::TemplateAST.register_directive(
  pattern: /\Adata-tooltip\z/, kind: :tooltip
)
Lilac::CLI::TemplateAST.register_directive(
  pattern: /\Adata-autofocus\z/, kind: :autofocus
)
Lilac::CLI::Codegen.register_emitter(:tooltip) do |codegen, directive, context|
  Lilac::CLI::ExtrasExtension.emit_tooltip(codegen, directive, context)
end
Lilac::CLI::Codegen.register_emitter(:autofocus) do |codegen, directive, context|
  Lilac::CLI::ExtrasExtension.emit_autofocus(codegen, directive, context)
end
