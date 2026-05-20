# frozen_string_literal: true

require_relative "builder"
require_relative "compiled_runtime_resolver"
require_relative "sfc"

module Lilac
  module CLI
    # Inspect a Lilac project for the common ways a fresh `lilac new`
    # fails before the user sees the page boot. Catches missing wasm
    # runtime, dangling `<lilac-component>` references, unparseable
    # `.lil`, and similar setup problems.
    #
    # `run` returns 0 when every check passes (or only warns); 1 when
    # any check produced an :error result. Output is plain-text and
    # mirrors the layout of `rails about` / `bundle doctor` /
    # `npx ... doctor` — one line per check, prefix marks the level.
    class Doctor
      Result = Struct.new(:level, :message, keyword_init: true)

      # Where the wasm runtime is expected to live, relative to public_dir.
      # Both live under `vendor/lilac-full/` so the target-aware public
      # mirror can prune them when building `--target compiled`.
      RUNTIME_WASM = "vendor/lilac-full/lilac-full.wasm"
      RUNTIME_JS_ADAPTER = "vendor/lilac-full/mruby-wasm-js/index.js"

      def initialize(config, out: $stdout)
        @config = config
        @out = out
      end

      # Returns exit status (0 if no errors).
      def run
        results = run_checks
        emit(results)
        results.any? { |r| r.level == :error } ? 1 : 0
      end

      private

      # Each check returns a single Result. Order is roughly "structure
      # → content → external assets" so the report reads top-down from
      # project layout outward.
      def run_checks
        [
          check_pages_dir,
          check_components_dir,
          *check_components_parse,
          *check_component_references,
          check_unused_components,
          check_public_dir,
          check_runtime_wasm,
          check_js_adapter,
          check_compiled_runtime,
        ]
      end

      def check_pages_dir
        if File.directory?(@config.pages_dir)
          ok("pages/ directory found at #{relative(@config.pages_dir)}")
        else
          error("pages/ directory missing: #{relative(@config.pages_dir)}")
        end
      end

      def check_components_dir
        if File.directory?(@config.components_dir)
          ok("components/ directory found at #{relative(@config.components_dir)}")
        else
          warn("components/ directory missing: #{relative(@config.components_dir)} (OK if you have no components yet)")
        end
      end

      # Each .lil file gets its own Result so a parse failure pinpoints
      # the offending file (rather than aborting the whole report).
      def check_components_parse
        gnt_paths.map do |path|
          SFC.parse_file(path)
          ok("component parses: #{relative(path)}")
        rescue SFC::ParseError => e
          error("component parse error: #{relative(path)}: #{e.message}")
        end
      end

      def check_component_references
        return [] unless File.directory?(@config.pages_dir)

        component_names = gnt_paths.map { |p| File.basename(p, ".lil") }.to_set
        results = []
        page_paths.each do |page_path|
          html = File.read(page_path)
          html.scan(Builder::COMPONENT_PLACEHOLDER) do |dq, sq|
            name = dq || sq
            unless component_names.include?(name)
              results << error(
                "page #{relative(page_path)} references <lilac-component name=#{name.inspect}>, " \
                "but no components/#{name}.lil exists"
              )
            end
          end
        end
        results.empty? ? [ok("all <lilac-component> references resolve")] : results
      end

      def check_unused_components
        return ok("no components to check for usage") if gnt_paths.empty?

        component_names = gnt_paths.map { |p| File.basename(p, ".lil") }.to_set
        referenced = page_paths.flat_map do |page_path|
          File.read(page_path).scan(Builder::COMPONENT_PLACEHOLDER).map { |dq, sq| dq || sq }
        end.uniq.to_set

        unused = component_names - referenced
        if unused.empty?
          ok("all components are referenced from at least one page")
        else
          warn("unused components: #{unused.to_a.sort.join(', ')}")
        end
      end

      def check_public_dir
        if File.directory?(@config.public_dir)
          ok("public/ directory found at #{relative(@config.public_dir)}")
        else
          warn("public/ directory missing: #{relative(@config.public_dir)} (required for the wasm runtime)")
        end
      end

      def check_runtime_wasm
        path = File.join(@config.public_dir, RUNTIME_WASM)
        if File.file?(path)
          ok("mruby-wasm runtime present: #{relative(path)} (#{format_size(File.size(path))})")
        else
          error("mruby-wasm runtime missing: expected at #{relative(path)}")
        end
      end

      def check_js_adapter
        path = File.join(@config.public_dir, RUNTIME_JS_ADAPTER)
        if File.file?(path)
          ok("JS adapter present: #{relative(path)}")
        else
          error("JS adapter missing: expected at #{relative(path)}")
        end
      end

      # `lilac build` defaults to `--target compiled`, which requires
      # a discoverable `lilac-compiled.wasm` (monorepo build/ dir, npm
      # package, or explicit config). This check reports whether one is
      # available, but doesn't fail the run — `lilac dev` and
      # `lilac build --target full` work without it, so a project that
      # only uses the full target shouldn't be forced to set up
      # compiled deps.
      def check_compiled_runtime
        resolver = CompiledRuntimeResolver.new(
          lilac_compiled_path: @config.lilac_compiled_path,
          mruby_wasm_js_path: @config.mruby_wasm_js_path,
          project_root: @config.root,
        )
        path = resolver.send(:resolve_wasm)
        if path && File.file?(path)
          ok("compiled wasm discoverable: #{relative(path)} (#{format_size(File.size(path))})")
        else
          warn(
            "lilac-compiled.wasm not discoverable — `lilac build` (default " \
            "target=compiled) will fail. Either run `make lilac-compiled` " \
            "in the lilac monorepo, `npm install @takahashim/lilac-compiled` " \
            "in this project, or use `lilac build --target full` to skip it."
          )
        end
      end

      def gnt_paths
        return [] unless File.directory?(@config.components_dir)

        @gnt_paths ||= Dir.glob(File.join(@config.components_dir, "**", "*.lil"))
      end

      def page_paths
        return [] unless File.directory?(@config.pages_dir)

        @page_paths ||= Dir.glob(File.join(@config.pages_dir, "**", "*.html"))
      end

      def relative(path)
        rel = Pathname.new(path).relative_path_from(Pathname.new(@config.root)).to_s
        # Paths outside the project root produce ugly `../../../../...`
        # forms — fall back to the absolute path which is easier to
        # read (and grep) than a long traversal sequence.
        rel.start_with?("../..") ? path : rel
      rescue ArgumentError
        path
      end

      def format_size(bytes)
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024.0)).round(1)} MB"
      end

      def ok(msg)
        Result.new(level: :ok, message: msg)
      end

      def warn(msg)
        Result.new(level: :warn, message: msg)
      end

      def error(msg)
        Result.new(level: :error, message: msg)
      end

      def emit(results)
        results.each { |r| @out.puts "  #{prefix(r.level)} #{r.message}" }
        @out.puts
        @out.puts summary(results)
      end

      def prefix(level)
        case level
        when :ok then "[OK]   "
        when :warn then "[WARN] "
        when :error then "[FAIL] "
        end
      end

      def summary(results)
        ok_count = results.count { |r| r.level == :ok }
        warn_count = results.count { |r| r.level == :warn }
        error_count = results.count { |r| r.level == :error }
        "#{ok_count} ok, #{warn_count} warning(s), #{error_count} error(s)"
      end
    end
  end
end
