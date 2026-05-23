# Specs for Scanner.register_named_directive (convention-based plug-in
# registration). Verifies dispatch routing, name format / collision /
# reserved-name detection.

# Helper: ensure a fresh registration each test by removing the key
# from EXTENSIONS before / after.
def with_clean_registry(name, &block)
  kind = name.to_sym
  Lilac::Directives::Scanner::EXTENSIONS[:directives].delete(kind)
  block.call
ensure
  Lilac::Directives::Scanner::EXTENSIONS[:directives].delete(kind)
end

Spec.describe "Scanner.register_named_directive" do
  Spec.assert "dispatch routes to handler.hook_<name>" do
    with_clean_registry("probe-tip") do
      mod = Module.new do
        def self.hook_probe_tip(_scanner, _raw_value, el, _item)
          # direct DOM mutation — sidesteps reactive bind to verify
          # the dispatch path itself fired
          el.call(:setAttribute, "title", "fixed")
        end
      end

      Lilac::Directives::Scanner.register_named_directive("probe-tip", handler: mod)

      body = JS.global[:document][:body]
      body[:innerHTML] = '<div data-component="ptr1"><span data-probe-tip></span></div>'
      klass = Class.new(Lilac::Component) { define_method(:setup) { } }
      Lilac.register("ptr1", klass)
      Lilac.start
      Lilac.flush_async!

      span = body.call(:querySelector, "span")
      Spec.assert_equal "fixed", span.call(:getAttribute, "title").to_s

      Lilac.reset!
      body[:innerHTML] = ""
      Lilac.flush_async!
    end
  end

  Spec.assert "hook may raise Lilac::Error for invalid raw_value (routes to logger.error)" do
    with_clean_registry("probe-raise") do
      mod = Module.new do
        def self.hook_probe_raise(_scanner, raw_value, _el, _item)
          raise Lilac::Error, "data-probe-raise: invalid #{raw_value.inspect}"
        end
      end
      Lilac::Directives::Scanner.register_named_directive("probe-raise", handler: mod)

      captured = []
      prev = Lilac.logger
      Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

      body = JS.global[:document][:body]
      body[:innerHTML] = '<div data-component="pr1"><span data-probe-raise="oops"></span></div>'
      klass = Class.new(Lilac::Component) { define_method(:setup) { } }
      Lilac.register("pr1", klass)
      Lilac.start
      Lilac.flush_async!

      err = captured.find { |level, _, _| level == :error }
      Spec.assert_true err, "expected logger.error for hook raise"
      Spec.assert_true err[2].to_s.include?("data-probe-raise"),
                       "error should mention directive label"

      Lilac.logger = prev
      Lilac.reset!
      body[:innerHTML] = ""
      Lilac.flush_async!
    end
  end

  Spec.assert "duplicate registration raises" do
    with_clean_registry("probe-dup") do
      mod = Module.new { def self.hook_probe_dup(*); end }
      Lilac::Directives::Scanner.register_named_directive("probe-dup", handler: mod)
      Spec.assert_raises(Lilac::Error) do
        Lilac::Directives::Scanner.register_named_directive("probe-dup", handler: mod)
      end
    end
  end

  Spec.assert "reserved built-in name raises" do
    mod = Module.new { def self.hook_text(*); end }
    Spec.assert_raises(Lilac::Error) do
      Lilac::Directives::Scanner.register_named_directive("text", handler: mod)
    end
  end

  Spec.assert "invalid name format raises ArgumentError" do
    mod = Module.new { def self.hook_x(*); end }
    Spec.assert_raises(ArgumentError) do
      Lilac::Directives::Scanner.register_named_directive("Bad-Name", handler: mod)
    end
    Spec.assert_raises(ArgumentError) do
      Lilac::Directives::Scanner.register_named_directive("data-prefixed", handler: mod)
    end
  end

  Spec.assert "missing handler: raises ArgumentError" do
    Spec.assert_raises(ArgumentError) do
      Lilac::Directives::Scanner.register_named_directive("probe-no-handler", handler: nil)
    end
  end
end
