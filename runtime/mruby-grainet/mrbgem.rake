MRuby::Gem::Specification.new("mruby-grainet") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Grainet — signal-first component system on top of mruby-wasm-js"

  # mruby-wasm-js lives in the separate mruby-wasm-runtime repo;
  # grainet's build_config registers it via an absolute path before
  # mruby-grainet loads, so name-resolution finds it without a `path:`
  # kwarg here. A `path:` would either be broken (the gem is not a
  # sibling of mruby-grainet in this repo) or would have to read
  # MRUBY_WASM_RUNTIME_PATH, which is build_config's job, not the
  # gem spec's.
  spec.add_dependency "mruby-wasm-js"
end
