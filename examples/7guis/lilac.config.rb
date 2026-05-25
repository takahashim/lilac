# frozen_string_literal: true

# Configuration for the 7GUIs reference gallery (`examples/7guis/`).
# Defaults are kept as-is; this file exists so `lilac dev` / `lilac build`
# can be run from this directory without flags.

Lilac::CLI.configure do |c|
  # c.components_dir = "components"
  # c.pages_dir      = "pages"
  # c.public_dir     = "public"
  # c.output_dir     = "dist"
  # c.dev_port       = 5173

  # Use the bundle delivery mode: all component templates (and Ruby
  # scripts, on :full target) are emitted into a single
  # `dist/lilac.bundle.html` that each page references via
  # `<link rel="lilac-bundle">`. The runtime fetches the bundle at
  # startup and injects its templates + scripts into the page.
  #
  # The 7GUIs gallery shares a `gallery-nav` component across every
  # task page, so a single bundle is more cache-friendly than per-page
  # inlines: each page HTML becomes much smaller, and updating
  # `gallery-nav.lil` invalidates only the bundle file, not every
  # page's HTML.
  c.delivery = :bundle
end
