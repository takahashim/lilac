# frozen_string_literal: true

require "pathname"
require_relative "build/vendor_writer"

module Lilac
  module CLI
    # Inspects a *built* dist directory and reports whether it is
    # self-contained — i.e. it can run with no internet access:
    #
    #   1. The target's runtime assets are vendored locally
    #      (`vendor/lilac-{full,compiled}/...`).
    #   2. No emitted HTML/JS loads a runtime asset from a remote origin
    #      (CDN import / `<script src>` / `<link href>` / `fetch()`).
    #
    # Outbound *content* links in page copy (`<a href="https://...">`)
    # are intentionally allowed — the guarantee is about runtime asset
    # loading, not about whether the page links elsewhere.
    #
    # Stateless; returns an Array of `Result` (level :ok / :warn / :error
    # — the same shape as `Doctor::Result`) so both `doctor` and any
    # future caller can consume it without duplication.
    class OfflineVerifier
      Result = Struct.new(:level, :message, keyword_init: true)

      # A remote URL appearing in an asset-loading position. We only flag
      # absolute (`https://host`, `http://host`) and protocol-relative
      # (`//host`) URLs; root-relative (`/vendor/...`) and bare-relative
      # (`./x.js`) paths are same-origin and fine. Captured inside the
      # asset-context patterns below so prose links don't false-positive.
      REMOTE_URL = %r{(?:https?:)?//[^"'\s)]+}

      # Asset-loading contexts whose URL must be local. Each captures the
      # URL into group 1.
      ASSET_CONTEXTS = [
        /\bimport\s+[^"']*["'](#{REMOTE_URL})["']/,             # import ... from "URL" / import "URL"
        /\bimport\s*\(\s*["'](#{REMOTE_URL})["']/,              # dynamic import("URL")
        /\bfrom\s+["'](#{REMOTE_URL})["']/,                     # from "URL"
        /\bfetch\s*\(\s*["'](#{REMOTE_URL})["']/,               # fetch("URL")
        /<script\b[^>]*\bsrc\s*=\s*["'](#{REMOTE_URL})["']/i,   # <script src="URL">
        /<link\b[^>]*\bhref\s*=\s*["'](#{REMOTE_URL})["']/i,    # <link href="URL"> (stylesheet/modulepreload)
        /\bnew\s+URL\s*\(\s*["'](#{REMOTE_URL})["']/,           # new URL("URL", ...)
      ].freeze

      def initialize(output_dir)
        @output_dir = output_dir
      end

      # Returns Array<Result>. Empty of :error/:warn ⇒ self-contained.
      def verify
        results = []
        results.concat(check_assets)
        results.concat(check_remote_refs)
        if results.empty?
          results << ok("dist is self-contained (offline-runnable): runtime assets " \
                        "vendored locally, no remote asset URLs")
        end
        results
      end

      private

      # Auto-detect which runtime the dist was built with by the presence
      # of its `vendor/lilac-{full,compiled}/` directory (a build emits
      # exactly one), then assert that runtime's required files are all
      # there. A dist with no vendored runtime can't run offline at all.
      def check_assets
        warnings = []
        any_present = false
        VendorWriter::REQUIRED_ASSETS.each_value do |files|
          # The target's vendor dir is the wasm's parent — derived from
          # the SSOT so the dir name isn't independently reconstructed.
          next unless File.directory?(File.join(@output_dir, File.dirname(files[:wasm])))
          any_present = true
          files.each_value do |rel|
            next if File.file?(File.join(@output_dir, rel))
            warnings << warn("incomplete vendored runtime: missing #{rel}")
          end
        end
        warnings << warn("no vendored runtime under vendor/ — dist won't run offline (build with a discoverable runtime)") unless any_present
        warnings
      end

      def check_remote_refs
        scan_files.flat_map do |file|
          remote_urls_in(File.read(file)).map do |url|
            warn("remote asset URL in #{relative(file)}: #{url} — vendor it locally for offline use")
          end
        end
      end

      def scan_files
        Dir.glob(File.join(@output_dir, "**", "*.{html,js}"), File::FNM_DOTMATCH)
           .select { |p| File.file?(p) }
      end

      # All distinct remote URLs that appear in an asset-loading context.
      def remote_urls_in(text)
        ASSET_CONTEXTS.flat_map { |re| text.scan(re).map { |m| m[0] } }.uniq
      end

      def relative(path)
        Pathname.new(path).relative_path_from(Pathname.new(@output_dir)).to_s
      rescue ArgumentError
        path
      end

      def ok(msg)
        Result.new(level: :ok, message: msg)
      end

      def warn(msg)
        Result.new(level: :warn, message: msg)
      end
    end
  end
end
