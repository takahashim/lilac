MRuby::Gem::Specification.new("mruby-lilac-form") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Lilac Form Builder — signal-based form state + validation for mruby-lilac"

  spec.add_dependency "mruby-lilac", path: File.expand_path("../mruby-lilac", __dir__)
end
