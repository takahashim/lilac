# frozen_string_literal: true

# Configuration for the package-extras example.
#
# After decisions §25/§26, Lilac packages are distributed as Ruby gems
# and picked up automatically when listed in the project's Gemfile —
# no `c.packages = [...]` config is needed for the standard path. See
# this directory's `Gemfile` for `gem "lilac-extras"`.
#
# `c.packages` remains available as an advanced override for explicit
# `.mrb` paths (vendored forks / pre-compiled artefacts not shipped as
# a gem). Most projects can leave it unset.

Lilac::CLI.configure do |_c|
  # No package overrides — auto-discovery via Bundler handles it.
end
