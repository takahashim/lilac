MRuby::Gem::Specification.new("mruby-lilac-form") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Lilac Form Builder — signal-based form state + validation for mruby-lilac"

  spec.add_dependency "mruby-lilac", path: File.expand_path("../mruby-lilac", __dir__)
  spec.add_dependency "mruby-lilac-directives",
                      path: File.expand_path("../mruby-lilac-directives", __dir__)
end
