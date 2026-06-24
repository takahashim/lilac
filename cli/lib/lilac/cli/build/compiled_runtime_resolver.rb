# frozen_string_literal: true

require_relative "runtime_resolver"

module Lilac
  module CLI
    # Locates the `target: :compiled` runtime that gets vendored into
    # `dist/vendor/lilac-compiled/`:
    #
    #   * `lilac.wasm`     — the compiled-variant wasm bundle (vendored
    #                        name; the monorepo/gem source is
    #                        `lilac-compiled.wasm`)
    #   * `mruby-wasm-js/` — the JS↔mruby bridge (resolved by the shared
    #                        base — same artifact as the :full target)
    #
    # The boot module is rendered inline by the builder
    # (`render_compiled_boot_module`); we don't ship the npm package's
    # `index.js`. Only the wasm-specific discovery differs from `:full`,
    # so this class supplies just those hooks. See `RuntimeResolver`.
    class CompiledRuntimeResolver < RuntimeResolver
      # Distinct from FullRuntimeResolver::Error; both < RuntimeResolver::Error.
      class Error < RuntimeResolver::Error; end

      def initialize(lilac_compiled_path: nil, **opts)
        super(lilac_wasm_path: lilac_compiled_path, **opts)
      end

      private

      def wasm_env_key
        "LILAC_COMPILED_WASM"
      end

      def gem_provided_wasm
        return nil if @disable_gem_discovery
        require "lilac/wasm/bin"
        ::Lilac::Wasm::Bin.lilac_compiled_wasm
      rescue LoadError
        nil
      end

      def monorepo_wasm_candidate
        File.join(monorepo_root, "build", "lilac-compiled.wasm")
      end

      def wasm_not_found_message
        <<~MSG.strip
          lilac-compiled.wasm not found. Tried:
            • configured `c.lilac_compiled_path` (#{@configured_wasm_path.inspect})
            • ENV["LILAC_COMPILED_WASM"] (#{ENV["LILAC_COMPILED_WASM"].inspect})
            • lilac-wasm-bin gem (not on load path)
            • monorepo: #{monorepo_wasm_candidate}

          To fix, either:
            • Add `gem "lilac-wasm-bin"` to your Gemfile (recommended — the scaffolded Gemfile from `lilac new` already includes it)
            • Pass `--lilac-compiled-path /abs/path/to/lilac.wasm` on the command line
            • Add `c.lilac_compiled_path = "/abs/path"` to lilac.config.rb
            • Set ENV["LILAC_COMPILED_WASM"]
            • In the monorepo: run `make lilac-compiled` to produce build/lilac-compiled.wasm
        MSG
      end
    end
  end
end
