# frozen_string_literal: true

# Project-wide lilac-cli configuration. Uncomment any field to
# override the corresponding built-in default. CLI flags (e.g.
# `lilac dev --port 8000`) take precedence over values set here.

Lilac::CLI.configure do |c|
  # c.components_dir = "components"     # where .lil components live
  # c.pages_dir   = "pages"       # where .html pages live
  # c.public_dir  = "public"      # static-passthrough directory
  # c.output_dir  = "dist"        # build output

  # c.dev_host    = "127.0.0.1"   # `lilac dev` bind host
  # c.dev_port    = 5173          # `lilac dev` bind port

  # Runtime wasm + bridge discovery overrides. All default to nil, in
  # which case the CLI auto-discovers via env vars, the `lilac-wasm-bin`
  # gem (recommended — already in the scaffolded Gemfile), or a monorepo
  # ancestor. Set these to vendor a specific wasm for a fully offline,
  # CDN-free build.
  # c.lilac_full_path     = "/abs/path/to/lilac-full.wasm"      # --target full
  # c.lilac_compiled_path = "/abs/path/to/lilac-compiled.wasm"  # --target compiled
  # c.mruby_wasm_js_path  = "/abs/path/to/mruby-wasm-js/"       # JS bridge (both targets)
end
