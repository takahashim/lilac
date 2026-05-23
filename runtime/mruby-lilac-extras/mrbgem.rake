MRuby::Gem::Specification.new("mruby-lilac-extras") do |spec|
  spec.license = "MIT"
  spec.author  = "takahashim"
  spec.summary = "Lilac extras — small directive plug-ins (tooltip, focus, autofocus)"

  spec.add_dependency "mruby-lilac",            path: File.expand_path("../mruby-lilac", __dir__)
  spec.add_dependency "mruby-lilac-directives",
                      path: File.expand_path("../mruby-lilac-directives", __dir__)
end
