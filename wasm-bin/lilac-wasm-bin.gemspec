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

  # wasmtime-rb drives mrbc-host.wasm from the host Ruby in lilac-cli's
  # WasmMrbcDriver. Declaring it here (instead of on lilac-cli) means
  # `bundle install` of a scaffolded project's Gemfile pulls in the
  # wasm runtime + driver together — keeping the "compile Ruby to
  # bytecode" pieces shipped as one unit.
  #
  # The version pin is the minimum that exposes `Engine.new(wasm_exceptions:)`
  # (needed because mrbc-host.wasm uses the wasm exception-handling
  # proposal). Released in wasmtime-rb v45.0.0 (2026-05, bundling the
  # `expose-wasm-exceptions` work from bytecodealliance/wasmtime-rb#599).
  spec.add_dependency "wasmtime", "~> 45.0"

  spec.metadata = {
    "source_code_uri" => "https://github.com/takahashim/lilac",
    "rubygems_mfa_required" => "true",
  }
end
