MRuby::Gem::Specification.new("mruby-host-compile") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Expose mruby's compiler as wasm exports so a Ruby host (via wasmtime-rb) can drive lilac-full.wasm in place of the mrbc binary."

  # Pulls in the parser + codegen + bytecode dumper. lilac-full.wasm
  # already transitively depends on these via mruby-wasm-js's
  # mruby-compiler dep — declaring it here too keeps the gem
  # self-describing when read in isolation.
  spec.add_dependency "mruby-compiler", core: "mruby-compiler"
end
