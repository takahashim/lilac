# frozen_string_literal: true

require_relative "lib/dommy/version"

Gem::Specification.new do |spec|
  spec.name        = "dommy"
  spec.version     = Dommy::VERSION
  spec.authors     = ["takahashim"]
  spec.summary     = "happy-dom-style DOM polyfill in pure Ruby"
  spec.description = <<~DESC
    Dommy is a DOM polyfill for Ruby. It provides Document, Element,
    Event, MutationObserver, Scheduler (setTimeout / rAF / microtask),
    Promise, Location / History / URL, localStorage, fetch (stub mode),
    and AbortController on top of Nokogiri::HTML5.

    Targeted at testing Ruby code that emits or consumes HTML with
    browser-like DOM semantics — a Ruby-side analogue to happy-dom.

    Also serves as the test harness DOM backend for Lilac
    (mruby-on-wasm SPA framework) via a JS bridge view of the same
    objects.
  DESC

  spec.required_ruby_version = ">= 3.0"
  spec.files                 = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths         = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.15"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
