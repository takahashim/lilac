# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "lilac-async"
  spec.version = "0.1.0"
  spec.authors = ["takahashim"]

  spec.summary = "Lilac package: async data primitives (Fetchy, Lilac::Resource, selector helpers)"
  spec.description = "Provides the `Fetchy` HTTP client, `Lilac::Resource` " \
                     "(signal-backed async data source), and selector " \
                     "helpers (`selector` / `select`). Designed for the " \
                     "lilac-compiled wasm variant; lilac-full already links " \
                     "the async gem in. Picked up automatically by " \
                     "`lilac build` via Bundler when the gem appears in the " \
                     "project's Gemfile."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # See lilac-extras.gemspec for the mrblib source distribution rationale.
  spec.files = Dir["mrblib/**/*.rb", "*.gemspec"]

  spec.metadata = {
    "lilac_package"         => "true",
    "source_code_uri"       => "https://github.com/takahashim/lilac",
    "rubygems_mfa_required" => "true",
  }
end
