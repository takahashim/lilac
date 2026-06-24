# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require_relative 'sfc'
require_relative 'bytecode_builder'
require_relative 'html_emitter'
require_relative 'template_ast_cache'
require_relative 'build_context'
require_relative 'bundle_asset_writer'
require_relative 'package_stager'
require_relative 'vendor_writer'
require_relative 'compiled_runtime_resolver'
require_relative 'full_runtime_resolver'
require_relative 'page_compiler'
require_relative '../lint/build_linter'

module Lilac
  module CLI
    # Orchestrates a full build: loads components, stages packages,
    # writes the (optional) bundle file, compiles each page via
    # `PageCompiler`, then vendors runtime assets into `dist/vendor/`.
    #
    # The per-page rewriting logic lives in `PageCompiler`; HTML helpers
    # in `HtmlEmitter`; template parse caching in `TemplateASTCache`;
    # all of those share state through the `BuildContext` value object
    # this class assembles.
    class Builder
      class Error < StandardError; end

      # Filenames that must not land in the build output even when they
      # exist under `public/`. Add to this list as new conventions are
      # encountered (e.g. `.DS_Store`, `Thumbs.db`).
      EXCLUDED_BASENAMES = %w[.gitkeep].freeze

      # Target-specific public/ subdirectories that should NOT be mirrored
      # into dist/ for the inactive target. Both runtime variants live
      # under their own namespace in `public/vendor/` so a project that
      # ships both (e.g. dev=full, prod=compiled) can keep them side by
      # side and let the CLI prune the inactive one at build time.
      #
      # Paths are relative to `public_dir`, POSIX style. The match is on
      # path prefix + boundary, so `vendor/lilac-full` matches
      # `vendor/lilac-full/lilac-full.wasm` but not `vendor/lilac-full-x`.
      EXCLUDED_DIRS_FOR_TARGET = {
        full: %w[vendor/lilac-compiled].freeze,
        compiled: %w[vendor/lilac-full].freeze
      }.freeze

      # Construct a Builder from a resolved `Config`. Centralises the
      # Config-attr → Builder-kwarg mapping so callers in `Command` and
      # `DevServer` don't drift out of sync. Overridable kwargs cover
      # the per-caller differences:
      #
      #   - `target:` — Command picks `config.build_target`, DevServer
      #     picks `config.dev_target`. Defaults to the build target.
      #   - `delivery:` — either caller can pin a value here; both
      #     currently leave it unset so `config.delivery` wins (build
      #     and dev share the same delivery path, matching what ships
      #     to prod).
      #   - `live_reload:` — DevServer turns it on for SSE-driven page
      #     reload; `lilac build` leaves it off.
      def self.from_config(config, live_reload: false,
                           target: nil, delivery: nil)
        new(
          components_dir: config.components_dir,
          pages_dir: config.pages_dir,
          output_dir: config.output_dir,
          public_dir: config.public_dir,
          target: target || config.build_target,
          mrbc_path: config.mrbc_path,
          lilac_compiled_path: config.lilac_compiled_path,
          lilac_full_path: config.lilac_full_path,
          mruby_wasm_js_path: config.mruby_wasm_js_path,
          packages: config.packages,
          delivery: delivery || config.delivery,
          live_reload: live_reload
        )
      end

      def initialize(components_dir:, pages_dir:, output_dir:, public_dir: nil,
                     live_reload: false,
                     target: :full, mrbc_path: nil,
                     lilac_compiled_path: nil, lilac_full_path: nil,
                     mruby_wasm_js_path: nil,
                     packages: [],
                     disable_gem_discovery: false,
                     delivery: :inline)
        @components_dir = components_dir
        @pages_dir = pages_dir
        @output_dir = output_dir
        # public_dir is optional. When nil or absent on disk, the
        # mirroring step is skipped — projects that don't need static
        # passthrough (no vendor bundle, no images) work fine without
        # creating the directory.
        @public_dir = public_dir
        @live_reload = live_reload
        # `:full` — dist HTML loads inline Ruby via lilac-full wasm
        # (vm.evalScript). `:compiled` — Ruby is pre-compiled to
        # `.mrb` bytecode via `mrbc` and loaded by lilac-compiled wasm
        # (vm.loadBytecode). The compiled target shaves ~32% off the brotli
        # bundle but requires `mrbc` available at build time. See
        # `BytecodeBuilder` for path discovery.
        @target = target
        @mrbc_path = mrbc_path
        # Discovery hints for the compiled runtime — wasm + boot helper
        # + JS bridge. Used by `auto_vendor_compiled_runtime!` so the
        # built dist is fully self-contained and no manual cp into
        # `public/vendor/lilac-compiled/` is required.
        @lilac_compiled_path = lilac_compiled_path
        # Discovery hint for the full runtime wasm — parallel to
        # `@lilac_compiled_path`. Used by `auto_vendor_full_runtime!`
        # via `FullRuntimeResolver` so a `:full` build is reliably
        # self-contained (offline-runnable) without the CDN.
        @lilac_full_path     = lilac_full_path
        @mruby_wasm_js_path  = mruby_wasm_js_path
        # Pre-compiled Lilac package `.mrb` paths (absolute). For both
        # `:compiled` and `:full` builds these get staged under
        # `dist/packages/`; `:compiled` injects loadBytecode into the
        # generated boot module directly, `:full` writes a
        # `dist/lilac.packages.json` manifest the scaffold boot fetches.
        # See decisions §25 / §26.
        @packages            = Array(packages).map { |p| File.expand_path(p) }
        # Mirrors `CompiledRuntimeResolver` / `BytecodeBuilder`'s
        # `disable_gem_discovery:` — tests pass `true` so the gem-bundled
        # wasm doesn't satisfy lookups they're trying to isolate. Plumbed
        # through to both resolvers below.
        @disable_gem_discovery = disable_gem_discovery
        # `:inline` (default) — inject component definitions into each
        # page's HTML. `:bundle` — emit a single dist/lilac.bundle.html
        # referenced from pages via `<link rel="lilac-bundle">`. Runtime
        # registry fetches the bundle and injects templates + evals
        # scripts before mount.
        @delivery = delivery
      end

      def build
        components = load_components
        pages = Dir.glob(File.join(@pages_dir, '**', '*.html'))
        raise Error, "No pages found under #{@pages_dir.inspect}" if pages.empty?

        public_files = mirror_public_files

        template_cache = TemplateASTCache.new
        build_linter = BuildLinter.new
        # Resolve and stage package `.mrb` files once for the build —
        # the URLs are stable across pages so each page's boot module
        # can reference the same set. PackageStager owns both the
        # discovered + explicit input channels and the :full-only
        # `lilac.packages.json` manifest emission.
        package_dist_urls = PackageStager.new(
          packages: @packages,
          target: @target,
          output_dir: @output_dir,
          bytecode_builder: bytecode_builder
        ).run!

        # In :bundle delivery mode, emit a single dist/lilac.bundle.html
        # containing all components' templates + scripts. Pages then
        # reference it via <link rel="lilac-bundle">. Done once before
        # page processing so PageCompiler can inject the <link>.
        bundle_assets =
          if @delivery == :bundle
            BundleAssetWriter.new(
              components: components,
              template_cache: template_cache,
              target: @target,
              output_dir: @output_dir,
              bytecode_builder: bytecode_builder
            ).write!
          end

        context = BuildContext.new(
          components: components,
          bundle_assets: bundle_assets,
          package_dist_urls: package_dist_urls,
          template_cache: template_cache,
          build_linter: build_linter,
          bytecode_builder: bytecode_builder,
          target: @target,
          delivery: @delivery,
          live_reload: @live_reload,
          output_dir: @output_dir,
          pages_dir: @pages_dir,
        )

        compiler = PageCompiler.new(context)
        pages.each { |page_path| compiler.compile(page_path) }

        build_linter.warn_cross_page_signature_drift!

        # `:compiled` target needs the runtime (wasm + bridge + boot
        # helper) sitting under `dist/vendor/lilac-compiled/`. We emit
        # it from the CLI directly so users don't have to vendor the
        # npm package by hand. Skipped when no `.mrb` was actually
        # produced — pages without any Ruby script don't reference the
        # bootstrap module.
        auto_vendor_compiled_runtime! if @target == :compiled && Dir.glob(File.join(@output_dir, '*.mrb')).any?
        # :full vendor — symmetric to :compiled. Strict: raises with an
        # actionable message when no runtime is discoverable (so an
        # offline build can't silently ship without its wasm), unless the
        # assets are already vendored (manual / public-mirror workflow).
        auto_vendor_full_runtime! if @target == :full

        { pages: pages.length, components: components.length, public_files: public_files }
      end

      private

      # Mirror `public/**/*` → `output_dir/`. Preserves the relative
      # directory structure (e.g. `public/vendor/x.js` →
      # `output_dir/vendor/x.js`). Returns the number of files copied.
      #
      # `.gitkeep` is filtered so an empty placeholder file doesn't
      # land in the build output. Other dot-prefixed files (e.g.
      # `.well-known/`) are copied so users can publish standard web
      # conventions.
      def mirror_public_files
        return 0 unless @public_dir && File.directory?(@public_dir)

        excluded_dirs = EXCLUDED_DIRS_FOR_TARGET.fetch(@target, [])
        copied = 0
        Dir.glob(File.join(@public_dir, '**', '*'), File::FNM_DOTMATCH).each do |source|
          # File.file? already filters out the `.` / `..` directory
          # entries that FNM_DOTMATCH surfaces, so no extra guard needed.
          next unless File.file?(source)
          next if EXCLUDED_BASENAMES.include?(File.basename(source))

          rel = Pathname.new(source).relative_path_from(Pathname.new(@public_dir)).to_s
          next if excluded_dirs.any? { |prefix| rel == prefix || rel.start_with?("#{prefix}/") }

          dest = File.join(@output_dir, rel)
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(source, dest)
          copied += 1
        end
        copied
      end

      def load_components
        Dir.glob(File.join(@components_dir, '**', '*.lil')).to_h do |path|
          [File.basename(path, '.lil'), SFC.parse_file(path)]
        end
      end

      # Lazily instantiated so `:full` builds incur no mrbc resolution
      # cost (`BytecodeBuilder.new` itself is cheap, but keeping the
      # creation lazy keeps the `:full` happy path obviously side-effect-free).
      def bytecode_builder
        @bytecode_builder ||= BytecodeBuilder.new(
          mrbc_path: @mrbc_path,
          output_dir: @output_dir,
          disable_gem_discovery: @disable_gem_discovery
        )
      end

      # Lazily resolves the lilac-compiled runtime (wasm + bridge + boot
      # helper). Constructed only when target=:compiled actually emits a
      # `.mrb`, mirroring `bytecode_builder`'s "no cost on the happy
      # :full path" pattern.
      def compiled_runtime_resolver
        @compiled_runtime_resolver ||= CompiledRuntimeResolver.new(
          lilac_compiled_path: @lilac_compiled_path,
          mruby_wasm_js_path: @mruby_wasm_js_path,
          disable_gem_discovery: @disable_gem_discovery
        )
      end

      # Lazily resolves the lilac-full runtime (wasm + bridge), mirroring
      # `compiled_runtime_resolver`.
      def full_runtime_resolver
        @full_runtime_resolver ||= FullRuntimeResolver.new(
          lilac_full_path: @lilac_full_path,
          mruby_wasm_js_path: @mruby_wasm_js_path,
          disable_gem_discovery: @disable_gem_discovery
        )
      end

      # :full target: vendor lilac-full.wasm + bridge into
      # `dist/vendor/lilac-full/` so the scaffold-generated page
      # (`import { createVM } from "/vendor/lilac-full/..."`) finds its
      # runtime assets after `lilac build` — making the dist fully
      # self-contained / offline-runnable with no CDN.
      #
      # Strict, symmetric with `auto_vendor_compiled_runtime!`: raises
      # `FullRuntimeResolver::Error` (actionable message) when no runtime
      # can be discovered, rather than silently shipping a dist missing
      # its runtime. The one exception is the manual-vendor workflow: if
      # the assets are already present under the vendor dir (e.g. mirrored
      # from `public/vendor/lilac-full/` — `mirror_public_files` runs
      # before this — or copied by hand), we skip resolution entirely so
      # gem-less self-hosting still works.
      def auto_vendor_full_runtime!
        return if VendorWriter::REQUIRED_ASSETS[:full]
                    .each_value.all? { |rel| File.file?(File.join(@output_dir, rel)) }

        VendorWriter.copy!(
          wasm_src: full_runtime_resolver.resolve_wasm!,
          bridge_src: full_runtime_resolver.resolve_bridge!,
          vendor_dir: File.join(@output_dir, 'vendor', 'lilac-full'),
          wasm_name: 'lilac-full.wasm'
        )
      end

      # Emits `dist/vendor/lilac-compiled/{lilac.wasm,mruby-wasm-js/...}`
      # from the resolved runtime sources. The boot module itself is
      # rendered inline in the page HTML (see PageCompiler's
      # render_compiled_boot_module), so we don't need to vendor
      # `index.js`: the page imports the bridge directly and calls
      # `loadBytecode` itself.
      #
      # Raises `CompiledRuntimeResolver::Error` if a source is missing,
      # with an actionable message — the caller (the build command) lets
      # it propagate.
      def auto_vendor_compiled_runtime!
        VendorWriter.copy!(
          wasm_src: compiled_runtime_resolver.resolve_wasm!,
          bridge_src: compiled_runtime_resolver.resolve_bridge!,
          vendor_dir: File.join(@output_dir, 'vendor', 'lilac-compiled'),
          wasm_name: 'lilac.wasm'
        )
      end

    end
  end
end
