# frozen_string_literal: true

# Configuration for the plug-in-extras example.
#
# After decisions §25, plug-ins are distributed as Ruby gems and picked
# up automatically when listed in the project's Gemfile — no
# `c.plugins = [...]` config is needed for the standard path. See
# this directory's `Gemfile` for `gem "lilac-plugin-extras"`.
#
# `c.plugins` remains available as an advanced override for explicit
# `.mrb` paths (vendored forks / pre-compiled artefacts not shipped as
# a gem). Most projects can leave it unset.

Lilac::CLI.configure do |_c|
  # No plug-in overrides — auto-discovery via Bundler handles it.
end
