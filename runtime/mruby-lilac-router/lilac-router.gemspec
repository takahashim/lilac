# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "lilac-router"
  spec.version = "0.1.0"
  spec.authors = ["takahashim"]

  spec.summary = "Lilac package: signal-based URL routing (`Lilac::Router`)"
  spec.description = "Provides `Lilac::Router`, a signal-backed driver for " \
                     "SPA-style navigation against `window.location`. " \
                     "Designed for the lilac-compiled wasm variant; " \
                     "lilac-full already links the router gem in. Picked up " \
                     "automatically by `lilac build` via Bundler when the " \
                     "gem appears in the project's Gemfile."
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
