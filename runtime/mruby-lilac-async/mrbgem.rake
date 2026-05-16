MRuby::Gem::Specification.new("mruby-lilac-async") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Lilac async extensions — Fetchy, Resource, and Selector"

  spec.add_dependency "mruby-lilac", path: File.expand_path("../mruby-lilac", __dir__)
end
