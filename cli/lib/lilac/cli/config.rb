# frozen_string_literal: true

require_relative "config_loader"

module Lilac
  module CLI
    # Holds resolved paths and server settings for the build pipeline.
    # Three sources, in increasing precedence:
    #
    #   1. Built-in defaults (DEFAULT_* constants below)
    #   2. `lilac.config.rb` at the project root (via ConfigLoader)
    #   3. CLI flags (`--components`, `--port`, etc.)
    #
    # Most call sites should use `Config.load(opts)`, which performs the
    # three-way merge in one shot. `Config.new(...)` remains for tests
    # and callers that want to construct a config without a file.
    class Config
      DEFAULT_COMPONENTS_DIR = "components"
      DEFAULT_PAGES_DIR = "pages"
      DEFAULT_OUTPUT_DIR = "dist"
      # Static files in `public/` are mirrored to `output_dir/` at
      # build time (Vite / Eleventy / Astro convention). The directory
      # itself is optional — Builder skips silently when absent.
      DEFAULT_PUBLIC_DIR = "public"
      DEFAULT_DEV_HOST = "127.0.0.1"
      DEFAULT_DEV_PORT = 5173

      # Build target. `:full` (default) emits dist HTML with inline Ruby
      # script tags loaded by the lilac-full wasm at runtime — the
      # original Lilac story, no extra tooling needed. `:compiled` emits
      # pre-compiled mruby bytecode (`.mrb`) loaded by lilac-compiled
      # wasm — smaller production bundle (~32% brotli), but requires
      # `mrbc` in the build environment (see DEFAULT_MRBC_CANDIDATES).
      #
      # Mirrors Vite's dev/prod two-stage philosophy:
      # - `lilac dev` defaults to `:full` so the development loop stays
      #   mrbc-free and gets the runtime parser for fast iteration.
      # - `lilac build` defaults to `:compiled` so production deploys
      #   ship the smaller bundle by default — opt out with
      #   `--target full` when you want the runtime parser in dist.
      DEFAULT_BUILD_TARGET = :compiled
      DEFAULT_DEV_TARGET   = :full
      TARGET_VALUES = %i[full compiled].freeze

      # Delivery mode for component templates + scripts:
      #   :inline — embed everything in each page's HTML (current default)
      #   :bundle — emit a single lilac.bundle.html, page HTML references it
      #             via <link rel="lilac-bundle">
      DEFAULT_DELIVERY = :inline
      DELIVERY_VALUES = %i[inline bundle].freeze

      attr_reader :root, :components_dir, :pages_dir, :output_dir, :public_dir,
                  :dev_host, :dev_port,
                  :build_target, :dev_target, :mrbc_path,
                  :lilac_compiled_path, :mruby_wasm_js_path,
                  :packages, :delivery

      # Three-way merge: CLI opts > lilac.config.rb > built-in defaults.
      # `opts` keys mirror the keyword args of `initialize`; nil values
      # mean "no CLI override given" and let the file/default win.
      def self.load(root: nil, components_dir: nil, pages_dir: nil, output_dir: nil,
                    public_dir: nil, dev_host: nil, dev_port: nil,
                    build_target: nil, dev_target: nil, mrbc_path: nil,
                    lilac_compiled_path: nil, mruby_wasm_js_path: nil,
                    packages: nil, delivery: nil)
        resolved_root = File.expand_path(root || Dir.pwd)
        settings = ConfigLoader.load(resolved_root) || ConfigLoader::Settings.new

        new(
          root: resolved_root,
          components_dir: components_dir || settings.components_dir,
          pages_dir:   pages_dir   || settings.pages_dir,
          output_dir:  output_dir  || settings.output_dir,
          public_dir:  public_dir  || settings.public_dir,
          dev_host:    dev_host    || settings.dev_host,
          dev_port:    dev_port    || settings.dev_port,
          build_target: build_target || settings.build_target,
          dev_target:   dev_target   || settings.dev_target,
          mrbc_path:    mrbc_path    || settings.mrbc_path,
          lilac_compiled_path: lilac_compiled_path || settings.lilac_compiled_path,
          mruby_wasm_js_path:  mruby_wasm_js_path  || settings.mruby_wasm_js_path,
          packages:    packages    || settings.packages,
          delivery:    delivery    || settings.delivery,
        )
      end

      def initialize(root: nil, components_dir: nil, pages_dir: nil, output_dir: nil,
                     public_dir: nil, dev_host: nil, dev_port: nil,
                     build_target: nil, dev_target: nil, mrbc_path: nil,
                     lilac_compiled_path: nil, mruby_wasm_js_path: nil,
                     packages: nil, delivery: nil)
        # Use `|| Dir.pwd` rather than a default keyword so callers can
        # pass `root: opts[:root]` (often nil from un-set CLI flags)
        # without overriding the default to nil.
        @root = File.expand_path(root || Dir.pwd)
        @components_dir = expand(components_dir || DEFAULT_COMPONENTS_DIR)
        @pages_dir = expand(pages_dir || DEFAULT_PAGES_DIR)
        @output_dir = expand(output_dir || DEFAULT_OUTPUT_DIR)
        @public_dir = expand(public_dir || DEFAULT_PUBLIC_DIR)
        @dev_host = dev_host || DEFAULT_DEV_HOST
        @dev_port = dev_port || DEFAULT_DEV_PORT
        @build_target = normalize_target(build_target || DEFAULT_BUILD_TARGET, kind: "build_target")
        @dev_target   = normalize_target(dev_target   || DEFAULT_DEV_TARGET,   kind: "dev_target")
        # nil = auto-discover at use time (see BytecodeBuilder.resolve_mrbc).
        @mrbc_path = mrbc_path
        # nil = auto-discover via CompiledRuntimeResolver (env / monorepo
        # ancestor / node_modules).
        @lilac_compiled_path = lilac_compiled_path
        @mruby_wasm_js_path  = mruby_wasm_js_path
        # Pre-compiled Lilac package `.mrb` paths (advanced override
        # path — most users get packages via Bundler auto-discovery,
        # see decisions §25/§26). Each entry is resolved against `@root`
        # so relative paths Just Work. Nil from Config.load is
        # normalized to an empty array.
        @packages = (packages || []).map { |p| expand(p) }
        @delivery = normalize_delivery(delivery || DEFAULT_DELIVERY)
      end

      private

      def expand(path)
        File.expand_path(path, @root)
      end

      def normalize_target(value, kind:)
        sym = value.to_sym
        unless TARGET_VALUES.include?(sym)
          raise ArgumentError,
                "#{kind} must be one of #{TARGET_VALUES.inspect}, got #{value.inspect}"
        end
        sym
      end

      def normalize_delivery(value)
        sym = value.to_sym
        unless DELIVERY_VALUES.include?(sym)
          raise ArgumentError,
                "delivery must be one of #{DELIVERY_VALUES.inspect}, got #{value.inspect}"
        end
        sym
      end
    end
  end
end
