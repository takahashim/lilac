# frozen_string_literal: true

module Lilac
  module CLI
    # Reads `lilac.config.rb` from a project root. The file uses the
    # `Lilac::CLI.configure` DSL:
    #
    #   Lilac::CLI.configure do |c|
    #     c.components_dir = "src/components"
    #     c.dev_port    = 3000
    #   end
    #
    # Unset fields stay nil so callers (Config.load) can fall through to
    # their hardcoded defaults. The DSL is only callable during a
    # `ConfigLoader.load` invocation; calling it outside that context
    # raises, which catches typos like `Lilac.configure { ... }` in
    # arbitrary scripts.
    class ConfigLoader
      DEFAULT_FILENAME = "lilac.config.rb"

      # Fields here are the union of every value the CLI knows how to
      # configure. Keep in sync with Config defaults.
      #
      # `codegen` controls whether the CLI emits a
      # `Lilac::Bindings::<Class>#bind_template_hook` module that
      # pre-compiles directive bindings into Ruby. Values:
      #   :auto — default; CLI emits codegen so mount-time has zero
      #           directive-scanning overhead.
      #   :off  — CLI skips codegen; the runtime scanner interprets
      #           directives at mount time. Useful for parity-testing
      #           the runtime path against the .lil source, and for
      #           "I want to confirm my app works without the CLI
      #           optimization" smoke runs.
      Settings = Struct.new(
        :components_dir, :pages_dir, :public_dir, :output_dir,
        :dev_host, :dev_port,
        :codegen,
        # build_target / dev_target: `:full` (default) ships dist HTML
        # with inline Ruby + lilac-full wasm; `:compiled` ships .mrb
        # bytecode + lilac-compiled wasm. mrbc_path overrides the
        # auto-discovery in BytecodeBuilder.
        :build_target, :dev_target, :mrbc_path,
        # Overrides for the `--target compiled` runtime discovery
        # (see CompiledRuntimeResolver). Both nil = auto-discover via
        # env / monorepo ancestor / node_modules.
        :lilac_compiled_path, :mruby_wasm_js_path,
        # `packages` — Array<String> of paths (absolute or
        # project-root-relative) pointing at pre-compiled Lilac package
        # `.mrb` files. Advanced override; most users get packages via
        # Bundler auto-discovery (`Lilac::CLI::PackageDiscovery`).
        # At build time the CLI copies each to `dist/packages/` and
        # the generated boot script `loadBytecode`s them before user
        # code. See decisions §25 / §26 + `docs/lilac-package-spec.md`.
        :packages,
        # `delivery` — :inline (default) embeds component definitions
        # in each page's HTML; :bundle emits a single lilac.bundle.html
        # referenced from each page via <link rel="lilac-bundle">. See
        # lilac-proposals.md for the bundle-fetch strategy.
        :delivery,
        keyword_init: true,
      )

      class LoadError < StandardError; end

      # Loads `<root>/lilac.config.rb` if present and returns a
      # Settings struct (with nils for unset fields). Returns nil when
      # the file doesn't exist — callers treat that as "use defaults".
      def self.load(root, filename: DEFAULT_FILENAME)
        path = File.join(root, filename)
        return nil unless File.file?(path)

        settings = Settings.new
        with_settings(settings) do
          begin
            Kernel.load(path)
          rescue StandardError, ScriptError => e
            raise LoadError, "Error loading #{filename}: #{e.message}"
          end
        end
        settings
      end

      # Singleton stash so `Lilac::CLI.configure` can find the active
      # Settings without each config file passing it explicitly.
      def self.with_settings(settings)
        previous = Thread.current[:lilac_cli_settings]
        Thread.current[:lilac_cli_settings] = settings
        yield
      ensure
        Thread.current[:lilac_cli_settings] = previous
      end

      def self.current_settings
        Thread.current[:lilac_cli_settings]
      end
    end

    # Public DSL hook. `lilac.config.rb` calls this; outside a
    # ConfigLoader.load it raises so accidental misuse fails loudly.
    def self.configure
      settings = ConfigLoader.current_settings
      raise ConfigLoader::LoadError,
            "Lilac::CLI.configure must be called from lilac.config.rb" unless settings

      yield settings
    end
  end
end
