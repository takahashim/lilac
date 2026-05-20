# frozen_string_literal: true

require_relative "lib/lilac/wasm/bin/version"

Gem::Specification.new do |spec|
  spec.name = "lilac-wasm-bin"
  spec.version = Lilac::Wasm::Bin::VERSION
  spec.authors = ["takahashim"]

  spec.summary = "Lilac wasm runtimes (full + compiled) + JS bridge, packaged for rubygems"
  spec.description = "Ships the lilac-full.wasm, lilac-compiled.wasm and the " \
                     "mruby-wasm-js JS bridge as a single Ruby gem so that " \
                     "`bundle install` is enough to make `lilac dev` and " \
                     "`lilac build` work — no npm install, no manual cp."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # The wasm + bridge files live under `data/` and are populated by
  # `rake build:assets` (which copies from the monorepo's build output)
  # before `gem build`. They're gitignored so the source tree stays
  # small; the gem itself does carry them.
  spec.files = Dir["lib/**/*.rb", "README.md"] +
               Dir.glob("data/**/*", File::FNM_DOTMATCH).reject { |p| File.directory?(p) }

  # No runtime gem dependencies. wasmtime-rb is pulled by `lilac-cli`
  # only when its `WasmMrbcDriver` path is needed (Phase 2); this gem
  # just exposes binary assets.

  spec.metadata = {
    "source_code_uri" => "https://github.com/takahashim/lilac",
    "rubygems_mfa_required" => "true",
  }
end
