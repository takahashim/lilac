# frozen_string_literal: true

# Project-wide grainet-cli configuration. Uncomment any field to
# override the corresponding built-in default. CLI flags (e.g.
# `grainet dev --port 8000`) take precedence over values set here.

Grainet::CLI.configure do |c|
  # c.components_dir = "components"     # where .gnt components live
  # c.pages_dir   = "pages"       # where .html pages live
  # c.public_dir  = "public"      # static-passthrough directory
  # c.output_dir  = "dist"        # build output

  # c.dev_host    = "127.0.0.1"   # `grainet dev` bind host
  # c.dev_port    = 5173          # `grainet dev` bind port
end
