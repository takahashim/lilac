# frozen_string_literal: true

require "pathname"

module Lilac
  module CLI
    # Locates the two pieces of runtime infrastructure that the
    # `target: :compiled` build path emits into `dist/vendor/lilac-compiled/`:
    #
    #   * `lilac.wasm`  — the compiled-variant wasm bundle
    #   * `mruby-wasm-js/` — the JS↔mruby bridge dependency
    #
    # The boot module itself is rendered inline by the builder
    # (`render_compiled_boot_module`) — we don't ship the npm package's
    # `index.js`, which has historically drifted from the bridge's API
    # (`loadIrep` → `loadBytecode` etc.) and would force the CLI to
    # keep rewriting it.
    #
    # Discovery mirrors `BytecodeBuilder`'s mrbc discovery: explicit
    # CLI/config wins, then env, then a monorepo sibling layout (so this
    # repo's own `examples/7guis/` Just Works at dev time), then a
    # `node_modules/` lookup (so projects that `npm install
    # @takahashim/lilac-compiled` get the same behaviour).
    class CompiledRuntimeResolver
      class Error < StandardError; end

      WASM_BASENAME       = "lilac.wasm"
      NPM_PACKAGE_NAME    = "@takahashim/lilac-compiled"
      BRIDGE_PACKAGE_NAME = "@takahashim/mruby-wasm-js"

      def initialize(lilac_compiled_path: nil, mruby_wasm_js_path: nil,
                     project_root: Dir.pwd, monorepo_root: nil,
                     disable_gem_discovery: false)
        @configured_compiled_path = lilac_compiled_path
        @configured_bridge_path   = mruby_wasm_js_path
        @project_root             = project_root
        # Tests inject a dummy directory to keep the (real) monorepo
        # wasm from being discovered in unit tests; production callers
        # leave it nil and the gem-relative ancestor is used.
        @monorepo_root_override   = monorepo_root
        # When `lilac-wasm-bin` is on the load path (= scaffolded
        # project's Gemfile pulled it in), `gem_provided_wasm` returns
        # the bundled wasm. Tests that exercise the discovery fallback
        # chain explicitly pass `disable_gem_discovery: true` so the
        # gem's wasm doesn't satisfy a "nothing should resolve" expectation.
        @disable_gem_discovery    = disable_gem_discovery
      end

      # Absolute path to the compiled wasm. Raises with an actionable
      # message if none of the discovery routes turn up a readable file.
      def resolve_wasm!
        resolve_wasm || raise(Error, wasm_not_found_message)
      end

      # Directory tree that contains the bridge's `index.js` plus its
      # `wasi-preview1.js` / `_memory.js` / etc. — the entire `js/`
      # subtree from `mruby-wasm-runtime/mrbgem/mruby-wasm-js/` in the
      # monorepo case, or the published npm package root in the installed
      # case.
      def resolve_bridge!
        resolve_bridge || raise(Error, bridge_not_found_message)
      end

      private

      def resolve_wasm
        return @configured_compiled_path if File.file?(@configured_compiled_path.to_s)
        if (env = ENV["LILAC_COMPILED_WASM"]) && File.file?(env)
          return env
        end
        # `lilac-wasm-bin` gem (the recommended distribution path —
        # scaffolded Gemfiles declare it so `bundle install` brings
        # the wasm in automatically). Soft-required; absent gem just
        # falls through.
        if (gem_wasm = gem_provided_wasm) && File.file?(gem_wasm)
          return gem_wasm
        end
        monorepo_wasm_candidates.each { |c| return c if File.file?(c) }
        node_modules = node_modules_wasm_candidate
        return node_modules if node_modules && File.file?(node_modules)

        nil
      end

      def resolve_bridge
        if @configured_bridge_path
          return @configured_bridge_path if bridge_dir?(@configured_bridge_path)
        end
        if (env = ENV["MRUBY_WASM_JS_PATH"]) && bridge_dir?(env)
          return env
        end
        candidates = [
          gem_provided_bridge,        # `lilac-wasm-bin` gem (same priority as wasm)
          monorepo_bridge_candidate,
          node_modules_bridge_candidate,
          # Fallback: lilac-compiled npm package depends on the bridge
          # and may carry it inside its own nested node_modules.
          nested_bridge_under_compiled_candidate,
        ].compact
        candidates.find { |c| bridge_dir?(c) }
      end

      # Soft-requires the `lilac-wasm-bin` gem and returns the path it
      # publishes for `lilac-compiled.wasm`, or nil if the gem isn't on
      # the load path (= user's Gemfile doesn't include it). `lilac-cli`
      # itself doesn't depend on the gem — scaffolded projects do via
      # their template Gemfile, which is the canonical install path.
      def gem_provided_wasm
        return nil if @disable_gem_discovery
        require "lilac/wasm/bin"
        ::Lilac::Wasm::Bin.lilac_compiled_wasm
      rescue LoadError
        nil
      end

      # Same soft-require pattern for the JS bridge directory bundled
      # in the gem.
      def gem_provided_bridge
        return nil if @disable_gem_discovery
        require "lilac/wasm/bin"
        ::Lilac::Wasm::Bin.mruby_wasm_js_dir
      rescue LoadError
        nil
      end

      # Two monorepo candidates, checked in order:
      #
      #   1. `<root>/build/lilac-compiled.wasm` — freshly produced by
      #      `make lilac-compiled`. Matches the bridge in `mrbgem/mruby-wasm-js/`
      #      and the current `build_config/lilac-compiled.rb` (no -flto, so no
      #      stray `env.setjmp` import).
      #   2. `<root>/npm/lilac-compiled/lilac.wasm` — last npm-pack artefact.
      #      Only used as fallback; older publishes may carry the LTO-era
      #      `env.setjmp` import and fail at instantiation.
      def monorepo_wasm_candidates
        [
          File.join(monorepo_root, "build", "lilac-compiled.wasm"),
          File.join(monorepo_npm_root, "lilac-compiled", WASM_BASENAME),
        ]
      end

      def node_modules_wasm_candidate
        File.join(@project_root, "node_modules", NPM_PACKAGE_NAME, WASM_BASENAME)
      end

      def monorepo_bridge_candidate
        # mruby-wasm-runtime is a sibling repo of lilac (the lilac repo
        # itself doesn't carry the bridge source — it copies it into
        # `mrbgem/mruby-wasm-js/` for the `make serve` flow).
        candidate = File.join(monorepo_root, "mrbgem", "mruby-wasm-js", "js")
        candidate if File.directory?(candidate)
      end

      def node_modules_bridge_candidate
        File.join(@project_root, "node_modules", BRIDGE_PACKAGE_NAME)
      end

      def nested_bridge_under_compiled_candidate
        File.join(@project_root, "node_modules", NPM_PACKAGE_NAME,
                  "node_modules", BRIDGE_PACKAGE_NAME)
      end

      def bridge_dir?(path)
        File.directory?(path.to_s) && File.file?(File.join(path.to_s, "index.js"))
      end

      # The gem ships from `cli/`. In the monorepo this file lives at
      # `<repo>/cli/lib/lilac/cli/compiled_runtime_resolver.rb`, so
      # `<repo>` is four levels up. When installed via rubygems the cli/
      # gem is unpacked alone — there is no enclosing repo, so the
      # candidate paths simply won't exist, which is fine: discovery
      # falls through to node_modules / explicit overrides.
      def monorepo_root
        @monorepo_root ||= @monorepo_root_override || File.expand_path("../../../..", __dir__)
      end

      def monorepo_npm_root
        File.join(monorepo_root, "npm")
      end

      def wasm_not_found_message
        monorepo_lines = monorepo_wasm_candidates.map { |c| "    • monorepo: #{c}" }.join("\n")
        <<~MSG.strip
          lilac-compiled.wasm not found. Tried:
            • configured `c.lilac_compiled_path` (#{@configured_compiled_path.inspect})
            • ENV["LILAC_COMPILED_WASM"] (#{ENV["LILAC_COMPILED_WASM"].inspect})
            • lilac-wasm-bin gem (not on load path)
          #{monorepo_lines}
            • node_modules: #{node_modules_wasm_candidate}

          To fix, either:
            • Add `gem "lilac-wasm-bin"` to your Gemfile (recommended — the scaffolded Gemfile from `lilac new` already includes it)
            • Pass `--lilac-compiled-path /abs/path/to/lilac.wasm` on the command line
            • Add `c.lilac_compiled_path = "/abs/path"` to lilac.config.rb
            • Set ENV["LILAC_COMPILED_WASM"]
            • In the monorepo: run `make lilac-compiled` to produce build/lilac-compiled.wasm
            • Otherwise: run `npm install @takahashim/lilac-compiled` in the project root
        MSG
      end

      def bridge_not_found_message
        <<~MSG.strip
          @takahashim/mruby-wasm-js bridge not found. Tried:
            • configured `c.mruby_wasm_js_path` (#{@configured_bridge_path.inspect})
            • ENV["MRUBY_WASM_JS_PATH"] (#{ENV["MRUBY_WASM_JS_PATH"].inspect})
            • lilac-wasm-bin gem (not on load path)
            • monorepo: #{monorepo_bridge_candidate || '(no mrbgem/mruby-wasm-js/js dir)'}
            • node_modules: #{node_modules_bridge_candidate}
            • nested under lilac-compiled: #{nested_bridge_under_compiled_candidate}

          To fix, either:
            • Add `gem "lilac-wasm-bin"` to your Gemfile (recommended)
            • Pass `--mruby-wasm-js-path /abs/path/to/mruby-wasm-js/` on the command line
            • Add `c.mruby_wasm_js_path = "/abs/path"` to lilac.config.rb
            • Set ENV["MRUBY_WASM_JS_PATH"]
            • Run `npm install @takahashim/mruby-wasm-js` in the project root
        MSG
      end
    end
  end
end
