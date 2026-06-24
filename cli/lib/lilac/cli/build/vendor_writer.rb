# frozen_string_literal: true

require 'fileutils'

module Lilac
  module CLI
    # Stages a wasm runtime + its JS bridge into `dist/vendor/<name>/`
    # so a built site is fully self-contained. Used for both the
    # `:full` and `:compiled` target vendor steps — the two paths only
    # differ in how the source files are resolved (gem soft-require vs
    # CompiledRuntimeResolver) and in the vendored wasm's filename.
    # The copy mechanics — mkdir, single-file wasm cp, bridge dir
    # walk skipping subdirectories — are the same for both.
    module VendorWriter
      # Single source of truth for the runtime assets a self-contained
      # (offline-runnable) dist must carry, per build target, as paths
      # relative to the dist root. Consumed by `Builder` (the :full skip
      # guard), `OfflineVerifier` (presence check), and `Doctor`
      # (`RUNTIME_WASM` / `RUNTIME_JS_ADAPTER`) so the definition of "a
      # complete vendored runtime" lives in exactly one place.
      #
      # Each value names its roles (`:wasm` / `:bridge`) so consumers
      # reference by meaning, not array position. The wasm basename
      # differs by target (`lilac-full.wasm` vs the vendored `lilac.wasm`);
      # the bridge entry is the shared `mruby-wasm-js/index.js`. The
      # vendor directory of a target is `File.dirname(...[:wasm])`.
      REQUIRED_ASSETS = {
        full: {
          wasm:   'vendor/lilac-full/lilac-full.wasm',
          bridge: 'vendor/lilac-full/mruby-wasm-js/index.js',
        }.freeze,
        compiled: {
          wasm:   'vendor/lilac-compiled/lilac.wasm',
          bridge: 'vendor/lilac-compiled/mruby-wasm-js/index.js',
        }.freeze,
      }.freeze

      module_function

      # Copy `wasm_src` to `<vendor_dir>/<wasm_name>` and every regular
      # file directly inside `bridge_src` to `<vendor_dir>/mruby-wasm-js/`.
      # Subdirectories of `bridge_src` are intentionally skipped — the
      # bridge ships as a flat js/ directory and any nested folders are
      # build artifacts the runtime doesn't read.
      def copy!(wasm_src:, bridge_src:, vendor_dir:, wasm_name:)
        bridge_out = File.join(vendor_dir, 'mruby-wasm-js')
        FileUtils.mkdir_p(bridge_out)

        FileUtils.cp(wasm_src, File.join(vendor_dir, wasm_name))
        Dir.glob(File.join(bridge_src, '*')).each do |entry|
          next if File.directory?(entry)

          FileUtils.cp(entry, File.join(bridge_out, File.basename(entry)))
        end
      end
    end
  end
end
