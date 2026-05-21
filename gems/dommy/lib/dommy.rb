# frozen_string_literal: true

require "nokogiri"

require_relative "dommy/version"
require_relative "dommy/node"
require_relative "dommy/event"
require_relative "dommy/scheduler"
require_relative "dommy/observer"
require_relative "dommy/promise"
require_relative "dommy/storage"
require_relative "dommy/fetch"
require_relative "dommy/router"
require_relative "dommy/navigator"
require_relative "dommy/parser"
require_relative "dommy/attr"
require_relative "dommy/world"
require_relative "dommy/document"
require_relative "dommy/element"
require_relative "dommy/html_elements"
require_relative "dommy/shadow_root"
require_relative "dommy/custom_elements"
require_relative "dommy/tree_walker"

module Dommy
  # Parse an HTML string and return a fresh `Window` whose document
  # body holds the parsed content. The Window has no host (CRuby
  # standalone usage); embedders that need bridge callbacks (Lilac /
  # mruby-wasm) pass a host instead.
  def self.parse(html)
    window = Window.new
    window.document.body.inner_html = html.to_s
    window
  end

  # Build a fresh, empty Window (no host). Equivalent to opening a
  # blank document.
  def self.new_window
    Window.new
  end
end
