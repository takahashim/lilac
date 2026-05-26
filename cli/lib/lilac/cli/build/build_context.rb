# frozen_string_literal: true

module Lilac
  module CLI
    # Per-build shared state handed from `Builder` (orchestrator) to
    # `PageCompiler` (per-page compiler). All fields are set before the
    # page loop starts, so PageCompiler treats the struct as read-only;
    # the cache / linter references inside it accumulate per-page state
    # via their own APIs.
    #
    # Fields:
    #   - `components`        — { name => SFC::Component }, .lil + synthesized
    #   - `bundle_assets`     — BundleAssetWriter::BundleAssets or nil (:inline mode)
    #   - `package_dist_urls` — Array<String> page-relative URLs for `.mrb` packages
    #   - `template_cache`    — shared TemplateASTCache (parse once, reuse)
    #   - `build_linter`      — BuildLinter accumulating cross-page diagnostics
    #   - `bytecode_builder`  — BytecodeBuilder for compiled-target `.mrb` emission
    #   - `target`            — :full | :compiled
    #   - `codegen`           — :auto | :off
    #   - `delivery`          — :inline | :bundle
    #   - `live_reload`       — boolean (dev path injects SSE client script)
    #   - `output_dir`        — absolute dist path (relative refs in boot module need this)
    #   - `pages_dir`         — absolute pages root (for computing output paths)
    BuildContext = Struct.new(
      :components, :bundle_assets, :package_dist_urls,
      :template_cache, :build_linter, :bytecode_builder,
      :target, :codegen, :delivery, :live_reload,
      :output_dir, :pages_dir,
      keyword_init: true
    )
  end
end
