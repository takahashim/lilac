# frozen_string_literal: true

require_relative "runtime_resolver"

module Lilac
  module CLI
    # Locates the `target: :full` runtime that gets vendored into
    # `dist/vendor/lilac-full/`:
    #
    #   * `lilac-full.wasm` — the full-variant wasm bundle (parser +
    #                         directive scanner + bundled gems)
    #   * `mruby-wasm-js/`  — the JS↔mruby bridge (resolved by the shared
    #                         base — same artifact as the :compiled target)
    #
    # Only the wasm-specific discovery differs from `:compiled`, so this
    # class supplies just those hooks. See `RuntimeResolver`.
    class FullRuntimeResolver < RuntimeResolver
      # Distinct from CompiledRuntimeResolver::Error; both < RuntimeResolver::Error.
      class Error < RuntimeResolver::Error; end

      def initialize(lilac_full_path: nil, **opts)
        super(lilac_wasm_path: lilac_full_path, **opts)
      end

      private

      def wasm_env_key
        "LILAC_FULL_WASM"
      end

      def gem_provided_wasm
        return nil if @disable_gem_discovery
        require "lilac/wasm/bin"
        ::Lilac::Wasm::Bin.lilac_full_wasm
      rescue LoadError
        nil
      end

      def monorepo_wasm_candidate
        File.join(monorepo_root, "build", "lilac-full.wasm")
      end

      def wasm_not_found_message
        <<~MSG.strip
          lilac-full.wasm not found. Tried:
            • configured `c.lilac_full_path` (#{@configured_wasm_path.inspect})
            • ENV["LILAC_FULL_WASM"] (#{ENV["LILAC_FULL_WASM"].inspect})
            • lilac-wasm-bin gem (not on load path)
            • monorepo: #{monorepo_wasm_candidate}

          To fix, either:
            • Add `gem "lilac-wasm-bin"` to your Gemfile (recommended — the scaffolded Gemfile from `lilac new` already includes it)
            • Pass `--lilac-full-path /abs/path/to/lilac-full.wasm` on the command line
            • Add `c.lilac_full_path = "/abs/path"` to lilac.config.rb
            • Set ENV["LILAC_FULL_WASM"]
            • In the monorepo: run `make lilac-full` to produce build/lilac-full.wasm
        MSG
      end
    end
  end
end
