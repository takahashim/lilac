MRuby::Gem::Specification.new("mruby-lilac-router") do |spec|
  spec.license = "MIT"
  spec.author = "takahashim"
  spec.summary = "Lilac Router — signal-based URL routing for mruby-lilac"

  spec.add_dependency "mruby-lilac", path: File.expand_path("../mruby-lilac", __dir__)
end
