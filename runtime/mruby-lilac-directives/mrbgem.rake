MRuby::Gem::Specification.new("mruby-lilac-directives") do |spec|
  spec.license = "MIT"
  spec.author  = "takahashim"
  spec.summary = "Runtime directive scanner for Lilac — interprets data-* directives at mount time"

  spec.add_dependency "mruby-lilac",
                      path: File.expand_path("../mruby-lilac", __dir__)
  spec.add_dependency "mruby-regexp-compat",
                      path: File.expand_path("../mruby-regexp-compat", __dir__)
end
