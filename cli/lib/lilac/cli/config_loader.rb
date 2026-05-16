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
      Settings = Struct.new(
        :components_dir, :pages_dir, :public_dir, :output_dir,
        :dev_host, :dev_port,
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
