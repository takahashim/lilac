# frozen_string_literal: true

require_relative "bin/version"

module Lilac
  module Wasm
    # Path resolution for the bundled wasm runtimes + JS bridge.
    #
    # Released gem layout:
    #   lilac-wasm-bin-X.Y.Z/
    #   ├── lib/lilac/wasm/bin.rb      ← this file
    #   └── data/
    #       ├── lilac-full.wasm
    #       ├── lilac-compiled.wasm
    #       ├── mrbc-host.wasm          (compiler-only wasm, driven via wasmtime-rb)
    #       └── mruby-wasm-js/
    #           ├── index.js
    #           ├── wasi-preview1.js
    #           └── ...
    #
    # Monorepo dev layout (via `gem "lilac-wasm-bin", path: "../wasm-bin"`):
    # `data/` may be empty or partially populated. As a fallback the
    # resolver walks up to the lilac monorepo root and reads from
    # `build/` (lilac-{full,compiled}.wasm) / `mrbgem/mruby-wasm-js/`
    # (bridge), so contributors don't have to `rake build:assets`
    # before every tweak.
    module Bin
      # Absolute path to this gem's `data/` directory — the canonical
      # location for the bundled wasm + bridge in a released gem.
      DATA_DIR = File.expand_path("../../../data", __dir__).freeze

      class << self
        # Path to lilac-full.wasm. Prefers the gem's data/; falls back
        # to `<monorepo>/build/lilac-full.wasm` for in-repo development.
        # Returns nil if neither exists.
        def lilac_full_wasm
          first_existing(
            File.join(DATA_DIR, "lilac-full.wasm"),
            File.join(monorepo_root, "build", "lilac-full.wasm"),
          )
        end

        # Path to lilac-compiled.wasm. Same discovery pattern.
        def lilac_compiled_wasm
          first_existing(
            File.join(DATA_DIR, "lilac-compiled.wasm"),
            File.join(monorepo_root, "build", "lilac-compiled.wasm"),
          )
        end

        # Path to mrbc-host.wasm — a compiler-only wasm reactor that
        # `lilac-cli`'s WasmMrbcDriver drives via wasmtime-rb to replace
        # the external `mrbc` binary for `lilac build --target compiled`.
        # Same gem-vs-monorepo discovery as the other variants.
        def mrbc_host_wasm
          first_existing(
            File.join(DATA_DIR, "mrbc-host.wasm"),
            File.join(monorepo_root, "build", "mrbc-host.wasm"),
          )
        end

        # Path to the JS bridge directory (`@takahashim/mruby-wasm-js`
        # source). The runtime wasms can't load without `index.js` +
        # `wasi-preview1.js` etc. siblings — the lilac-cli builder
        # auto-vendors the whole directory into `dist/vendor/.../`.
        def mruby_wasm_js_dir
          first_directory(
            File.join(DATA_DIR, "mruby-wasm-js"),
            File.join(monorepo_root, "mrbgem", "mruby-wasm-js", "js"),
          )
        end

        private

        # `lilac/` repo root one level above the wasm-bin gem. Only
        # meaningful in the monorepo dev layout (`gem ... path: ...`);
        # in a released gem this resolves to an arbitrary path under
        # ~/.gem and the file checks above simply produce no hits.
        # Kept as a method (not constant) so it's not exposed on the
        # public Bin namespace.
        def monorepo_root
          File.expand_path("../../../..", __dir__)
        end

        def first_existing(*paths)
          paths.find { |p| File.file?(p) }
        end

        def first_directory(*paths)
          paths.find { |p| File.directory?(p) }
        end
      end
    end
  end
end
