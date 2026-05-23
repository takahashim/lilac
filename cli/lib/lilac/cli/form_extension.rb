# frozen_string_literal: true

require_relative "codegen"
require_relative "template_ast"

# Form-related CLI extension. Owns the build-time codegen for
# `data-form` / `data-field` / `data-button` and the template-walk-side
# directive recognition. Registered with the CLI extension APIs from
# `Codegen.register_emitter` / `TemplateAST.register_directive`.
#
# This file is the CLI counterpart to runtime/mruby-lilac-form's
# `lilac_form_directives.rb` + `lilac_form_wiring.rb`. Belongs
# conceptually to the form gem; lives under `cli/lib/` until the
# gemspec / discovery story for packaging package CLI extensions
# is finalized.

module Lilac
  module CLI
    module FormExtension
      # Symbol literal for the emitted form name. `:default` for the
      # implicit scope, `:NAME` otherwise.
      def self.form_scope_literal(form_scope)
        (form_scope || :default).inspect
      end

      # Validate + symbolize a bare identifier directive value for
      # data-field / data-button.
      def self.parse_form_ident!(codegen, directive, label)
        name = directive.value.to_s.strip
        unless Lilac::Directives::Grammar.method_ident?(name)
          raise Codegen::Error.new(
            "#{label}=#{directive.value.inspect}: expected a bare identifier",
            at: directive.source_location(codegen.file),
          )
        end
        name.to_sym
      end

      # data-form on a <form> element → wire submit event to invoke_button(:submit).
      # Triggered for both `<form data-form="X">` (named scope) and bare
      # `<form>` (TemplateAST injects a synthetic :form directive with
      # empty value to ensure we emit the wire). preventDefault +
      # has_button? guard mirror the runtime scanner's wire_form_submit.
      def self.emit_form(codegen, directive, context)
        sym_literal = form_scope_literal(directive.form_scope)
        [
          "# #{codegen.file}:#{directive.line} — <form> submit wire for form(#{sym_literal})",
          "#{context.refs_expr}.#{directive.ref_id}.on(:submit) do |__ev|",
          "  __ev.call(:preventDefault)",
          "  __f = form(#{sym_literal})",
          "  __f.invoke_button(:submit, __ev) if __f.has_button?(:submit)",
          "end",
        ]
      end

      # data-field="NAME" → resolve enclosing form, ensure field is
      # registered (auto-register if Ruby didn't declare), bind_to the
      # discovered form control. Mirrors runtime Scanner's dispatch_field
      # minus the container-class / error-slot wiring (those land in a
      # follow-up Phase C extension; runtime scanner remains the canonical
      # source of those bindings).
      def self.emit_field(codegen, directive, context)
        sym = parse_form_ident!(codegen, directive, "data-field")
        scope = form_scope_literal(directive.form_scope)
        input_ref = directive.field_input_ref
        unless input_ref
          raise Codegen::Error.new(
            "data-field=#{directive.value.inspect}: no <input>, <textarea>, or " \
            "<select> found inside the element.",
            at: directive.source_location(codegen.file),
          )
        end
        [
          "# #{codegen.file}:#{directive.line} — data-field=#{directive.value.inspect} in form(#{scope})",
          "form(#{scope}).field(#{sym.inspect}) unless form(#{scope}).has_field?(#{sym.inspect})",
          "form(#{scope})[#{sym.inspect}].bind_to(#{context.refs_expr}.#{input_ref})",
        ]
      end

      # data-button="NAME" → wire click event to invoke_button(:NAME).
      # The handler raises at runtime if NAME isn't declared.
      def self.emit_button(codegen, directive, context)
        sym = parse_form_ident!(codegen, directive, "data-button")
        scope = form_scope_literal(directive.form_scope)
        [
          "# #{codegen.file}:#{directive.line} — data-button=#{directive.value.inspect} in form(#{scope})",
          "#{context.refs_expr}.#{directive.ref_id}.on(:click) { |__ev| form(#{scope}).invoke_button(#{sym.inspect}, __ev) }",
        ]
      end
    end
  end
end

# ---- registrations ---------------------------------------------------

Lilac::CLI::TemplateAST.register_directive(
  pattern: /\Adata-field\z/, kind: :field
)
Lilac::CLI::TemplateAST.register_directive(
  pattern: /\Adata-button\z/, kind: :button
)
# `:form` is already in TemplateAST::DIRECTIVE_PATTERNS for now because
# its synthetic injection for bare `<form>` elements still lives in
# `collect_directives_with_synthesis`. Migrating that to a true element
# hook is a follow-up; until then the registration here would shadow
# the built-in entry and risk double-detection.

Lilac::CLI::Codegen.register_emitter(:form) do |codegen, directive, context|
  Lilac::CLI::FormExtension.emit_form(codegen, directive, context)
end
Lilac::CLI::Codegen.register_emitter(:field) do |codegen, directive, context|
  Lilac::CLI::FormExtension.emit_field(codegen, directive, context)
end
Lilac::CLI::Codegen.register_emitter(:button) do |codegen, directive, context|
  Lilac::CLI::FormExtension.emit_button(codegen, directive, context)
end
