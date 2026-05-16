# frozen_string_literal: true

require_relative "lib/lilac/cli/version"

Gem::Specification.new do |spec|
  spec.name = "lilac-cli"
  spec.version = Lilac::CLI::VERSION
  spec.authors = ["takahashim"]

  spec.summary = "Build tool for Lilac single-file components (.lil)"
  spec.description = "lilac-cli compiles .lil single-file components " \
                     "(template + Ruby script) into static HTML for the Lilac " \
                     "component runtime on mruby-wasm."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"] +
               # FNM_DOTMATCH so dot-prefixed template files
               # (e.g. `public/.gitkeep`) are bundled in the gem.
               Dir.glob("lib/lilac/cli/templates/**/*", File::FNM_DOTMATCH)
                  .select { |p| File.file?(p) }
  spec.bindir = "exe"
  spec.executables = ["lilac"]
  spec.require_paths = ["lib"]

  # wsv powers `lilac dev` (static serving + custom app DI + SSE).
  # listen handles file-watch for live reload.
  # nokogiri parses `.lil` template bodies for directive extraction
  # (HTML5 fragment mode, attribute walking, source-line tracking).
  # prism parses the user's Ruby `<script>` body into a real AST so
  # the cross-reference linter can track signal/method declarations
  # and references precisely (helper-method calls, `send(:foo)`,
  # ivar reads inside `computed { ... }` blocks all resolve correctly).
  # Bundled with Ruby 3.3+; explicit dep covers the 3.2 baseline.
  spec.add_dependency "listen", "~> 3.9"
  spec.add_dependency "nokogiri", "~> 1.16"
  spec.add_dependency "prism", "~> 1.0"
  spec.add_dependency "wsv", "~> 0.10"

  spec.metadata["rubygems_mfa_required"] = "true"
end
