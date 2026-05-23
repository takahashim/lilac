# Specs for Scanner.register_named_directive (convention-based plug-in
# registration). Verifies dispatch routing, validation metadata
# enforcement, name format / collision / reserved-name detection.

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
        def self.hook_probe_tip(scanner, raw_value, el, item)
          # direct DOM mutation — sidesteps reactive bind to verify
          # the dispatch path itself fired
          el.call(:setAttribute, "title", "fixed")
        end
      end

      Lilac::Directives::Scanner.register_named_directive(
        "probe-tip", handler: mod, value: :none
      )

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

  Spec.assert "value: :reactive validates Value.parse" do
    with_clean_registry("probe-val") do
      mod = Module.new do
        def self.hook_probe_val(scanner, raw_value, el, item)
          value = Lilac::Directives::Value.parse(raw_value)
          source = scanner.evaluator.bind_source(value, item)
          scanner.host.bind(scanner.wrap_ref(el), attr: { "title" => source })
        end
      end
      Lilac::Directives::Scanner.register_named_directive(
        "probe-val", handler: mod, value: :reactive
      )

      captured = []
      prev = Lilac.logger
      Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

      body = JS.global[:document][:body]
      body[:innerHTML] = '<div data-component="pv1"><span data-probe-val="@bad.value"></span></div>'
      klass = Class.new(Lilac::Component) { define_method(:setup) { } }
      Lilac.register("pv1", klass)
      Lilac.start
      Lilac.flush_async!

      err = captured.find { |level, _, _| level == :error }
      Spec.assert_true err, "expected logger.error for invalid value"
      Spec.assert_true err[2].to_s.include?("data-probe-val"),
                       "error should mention directive name"

      Lilac.logger = prev
      Lilac.reset!
      body[:innerHTML] = ""
      Lilac.flush_async!
    end
  end

  Spec.assert "allowed_tags: restricts dispatch by element tag" do
    with_clean_registry("probe-tag") do
      mod = Module.new do
        def self.hook_probe_tag(scanner, raw_value, el, item)
          el.call(:focus)
        end
      end
      Lilac::Directives::Scanner.register_named_directive(
        "probe-tag", handler: mod, value: :none, allowed_tags: %w[input]
      )

      captured = []
      prev = Lilac.logger
      Lilac.logger = ->(level, msg, err) { captured << [level, msg.to_s, err ? err.message : nil] }

      body = JS.global[:document][:body]
      body[:innerHTML] = '<div data-component="pt1"><span data-probe-tag></span></div>'
      klass = Class.new(Lilac::Component) { define_method(:setup) { } }
      Lilac.register("pt1", klass)
      Lilac.start
      Lilac.flush_async!

      err = captured.find { |level, _, _| level == :error }
      Spec.assert_true err, "expected logger.error for disallowed tag"
      Spec.assert_true err[2].to_s.include?("not allowed on <span>"),
                       "error should explain allowed_tags violation"

      Lilac.logger = prev
      Lilac.reset!
      body[:innerHTML] = ""
      Lilac.flush_async!
    end
  end

  Spec.assert "duplicate registration raises" do
    with_clean_registry("probe-dup") do
      mod = Module.new { def self.hook_probe_dup(*); end }
      Lilac::Directives::Scanner.register_named_directive(
        "probe-dup", handler: mod, value: :none
      )
      Spec.assert_raises(Lilac::Error) do
        Lilac::Directives::Scanner.register_named_directive(
          "probe-dup", handler: mod, value: :none
        )
      end
    end
  end

  Spec.assert "reserved built-in name raises" do
    # Don't clean :text — it's a built-in we want to verify can't be overridden
    mod = Module.new { def self.hook_text(*); end }
    Spec.assert_raises(Lilac::Error) do
      Lilac::Directives::Scanner.register_named_directive(
        "text", handler: mod, value: :reactive
      )
    end
  end

  Spec.assert "invalid name format raises ArgumentError" do
    mod = Module.new { def self.hook_x(*); end }
    Spec.assert_raises(ArgumentError) do
      Lilac::Directives::Scanner.register_named_directive(
        "Bad-Name", handler: mod, value: :none
      )
    end
    Spec.assert_raises(ArgumentError) do
      Lilac::Directives::Scanner.register_named_directive(
        "data-prefixed", handler: mod, value: :none
      )
    end
  end

  Spec.assert "missing handler: raises ArgumentError" do
    Spec.assert_raises(ArgumentError) do
      Lilac::Directives::Scanner.register_named_directive(
        "probe-no-handler", handler: nil, value: :none
      )
    end
  end
end
