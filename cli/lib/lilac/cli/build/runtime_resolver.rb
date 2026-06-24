# frozen_string_literal: true

module Lilac
  module CLI
    # Shared discovery logic for the two build-target runtimes
    # (`:full` / `:compiled`). Both vendor a wasm bundle plus the SAME
    # mruby-wasm-js JS bridge into `dist/vendor/lilac-<target>/`, and both
    # discover sources in the same order: explicit CLI/config → env →
    # `lilac-wasm-bin` gem (the canonical install path — decisions §25) →
    # monorepo sibling layout for in-repo development.
    #
    # The bridge is identical across targets, so its resolution lives
    # here. Subclasses supply only the wasm-specific bits via the
    # protected hooks at the bottom (env key, gem accessor, monorepo
    # candidate, not-found message).
    class RuntimeResolver
      # Common ancestor so a caller can `rescue RuntimeResolver::Error`
      # for either target. Each subclass defines its own `Error <
      # RuntimeResolver::Error` and the `resolve_*!` methods raise
      # `self.class::Error`, so `FullRuntimeResolver::Error` and
      # `CompiledRuntimeResolver::Error` stay distinct (a rescue of one
      # doesn't swallow the other).
      class Error < StandardError; end

      def initialize(lilac_wasm_path: nil, mruby_wasm_js_path: nil,
                     monorepo_root: nil, disable_gem_discovery: false)
        @configured_wasm_path   = lilac_wasm_path
        @configured_bridge_path = mruby_wasm_js_path
        # Tests inject a dummy directory to keep the (real) monorepo wasm
        # from being discovered; production callers leave it nil and the
        # gem-relative ancestor is used.
        @monorepo_root_override = monorepo_root
        # Tests that exercise the fallback chain pass `true` so the gem's
        # wasm doesn't satisfy a "nothing should resolve" expectation.
        @disable_gem_discovery  = disable_gem_discovery
      end

      # Absolute path to the wasm, or nil if none of the discovery routes
      # turn up a readable file. Non-raising: use this to *report*
      # discoverability (Doctor); use `resolve_wasm!` on the build path
      # where absence must be a hard error.
      def wasm_path
        return @configured_wasm_path if File.file?(@configured_wasm_path.to_s)
        if (env = ENV[wasm_env_key]) && File.file?(env)
          return env
        end
        if (gem_wasm = gem_provided_wasm) && File.file?(gem_wasm)
          return gem_wasm
        end
        monorepo_wasm_candidate.then { |c| return c if File.file?(c) }

        nil
      end

      # Directory containing the bridge's `index.js`, or nil if not found.
      # Shared across targets — the bridge artifact is the same for both.
      def bridge_path
        if @configured_bridge_path
          return @configured_bridge_path if bridge_dir?(@configured_bridge_path)
        end
        if (env = ENV["MRUBY_WASM_JS_PATH"]) && bridge_dir?(env)
          return env
        end
        [
          gem_provided_bridge,        # `lilac-wasm-bin` gem (canonical install path)
          monorepo_bridge_candidate,
        ].compact.find { |c| bridge_dir?(c) }
      end

      # Raising variants for the build path: a missing runtime must fail
      # the build loudly with an actionable message.
      def resolve_wasm!
        wasm_path || raise(self.class::Error, wasm_not_found_message)
      end

      def resolve_bridge!
        bridge_path || raise(self.class::Error, bridge_not_found_message)
      end

      private

      # Soft-requires the `lilac-wasm-bin` gem for the bridge directory,
      # or nil if the gem isn't on the load path.
      def gem_provided_bridge
        return nil if @disable_gem_discovery
        require "lilac/wasm/bin"
        ::Lilac::Wasm::Bin.mruby_wasm_js_dir
      rescue LoadError
        nil
      end

      def monorepo_bridge_candidate
        candidate = File.join(monorepo_root, "mrbgem", "mruby-wasm-js", "js")
        candidate if File.directory?(candidate)
      end

      def bridge_dir?(path)
        File.directory?(path.to_s) && File.file?(File.join(path.to_s, "index.js"))
      end

      # The cli gem ships from `<repo>/cli`. This file lives at
      # `<repo>/cli/lib/lilac/cli/build/runtime_resolver.rb`, so `<repo>`
      # is five levels up. When installed via rubygems the cli gem is
      # unpacked alone — the candidates simply won't exist, which is fine:
      # discovery falls through to gem / explicit overrides.
      def monorepo_root
        @monorepo_root ||= @monorepo_root_override || File.expand_path("../../../../..", __dir__)
      end

      def bridge_not_found_message
        <<~MSG.strip
          @takahashim/mruby-wasm-js bridge not found. Tried:
            • configured `c.mruby_wasm_js_path` (#{@configured_bridge_path.inspect})
            • ENV["MRUBY_WASM_JS_PATH"] (#{ENV["MRUBY_WASM_JS_PATH"].inspect})
            • lilac-wasm-bin gem (not on load path)
            • monorepo: #{monorepo_bridge_candidate || '(no mrbgem/mruby-wasm-js/js dir)'}

          To fix, either:
            • Add `gem "lilac-wasm-bin"` to your Gemfile (recommended)
            • Pass `--mruby-wasm-js-path /abs/path/to/mruby-wasm-js/` on the command line
            • Add `c.mruby_wasm_js_path = "/abs/path"` to lilac.config.rb
            • Set ENV["MRUBY_WASM_JS_PATH"]
        MSG
      end

      # ---- wasm-specific hooks (subclasses must override) --------------

      # ENV var consulted for an explicit wasm path.
      def wasm_env_key
        raise NotImplementedError, "#{self.class} must define #wasm_env_key"
      end

      # Path the `lilac-wasm-bin` gem publishes for this target's wasm,
      # or nil if the gem isn't loadable / discovery is disabled.
      def gem_provided_wasm
        raise NotImplementedError, "#{self.class} must define #gem_provided_wasm"
      end

      # The monorepo `build/<wasm>` candidate for in-repo development.
      def monorepo_wasm_candidate
        raise NotImplementedError, "#{self.class} must define #monorepo_wasm_candidate"
      end

      # Actionable "wasm not found" message naming this target's overrides.
      def wasm_not_found_message
        raise NotImplementedError, "#{self.class} must define #wasm_not_found_message"
      end
    end
  end
end
