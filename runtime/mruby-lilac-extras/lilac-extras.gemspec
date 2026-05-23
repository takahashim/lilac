# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "lilac-extras"
  spec.version = "0.1.0"
  spec.authors = ["takahashim"]

  spec.summary = "Lilac package: `data-tooltip` and `data-autofocus` directives"
  spec.description = "Adds `data-tooltip` (bind the `title` attribute to a " \
                     "signal) and `data-autofocus` (focus the element after " \
                     "mount) to apps built with the lilac-compiled wasm " \
                     "variant. Picked up automatically by `lilac build` via " \
                     "Bundler when the gem appears in the project's Gemfile."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # mrblib `.rb` source is the canonical distribution. `lilac build`
  # compiles it to mruby bytecode at the user's build time so the
  # produced `.mrb` matches the locally-vendored core wasm's mruby
  # version — no peer-dep dance required.
  spec.files = Dir["mrblib/**/*.rb", "*.gemspec"]

  spec.metadata = {
    # Sentinel for `Lilac::CLI::PackageDiscovery`. lilac-cli walks
    # `Bundler.load.specs` and selects entries where this is "true",
    # then reads `mrblib/*.rb` to feed `lilac package-build`.
    "lilac_package"         => "true",
    "source_code_uri"       => "https://github.com/takahashim/lilac",
    "rubygems_mfa_required" => "true",
  }
end
