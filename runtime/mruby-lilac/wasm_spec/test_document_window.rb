Spec.describe "Component#document / #window" do
  # `Lilac.reset!` forcefully unmounts components from the previous case
  # so each starts from a clean registry even if the MutationObserver
  # unmount hasn't flushed yet.
  Spec.after { Lilac.reset! }

  Spec.assert "document / window return RefElements over the right JS objects" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dw-id"></div>'

    captured = nil
    klass = Class.new(Lilac::Component) do
      define_method(:setup) { captured = [document, window] }
    end
    Lilac.register "dw-id", klass
    Lilac.start

    d, w = captured
    Spec.assert_true Lilac::RefElement === d
    Spec.assert_true Lilac::RefElement === w
    # document wraps the Document node (nodeType 9); window exposes its
    # own `document` property (and is not the document itself).
    Spec.assert_equal 9, d[:nodeType].to_i
    Spec.assert_false w[:document].js_null?
  end

  Spec.assert "document.on listener fires and auto-cleans on unmount" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dw-doc"></div>'

    hits = 0
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        document.on(:lilac_doc_evt) { hits += 1 }
      end
    end
    Lilac.register "dw-doc", klass
    Lilac.start

    # Dispatch a CustomEvent on document — the wrapped listener should run.
    fire = lambda do
      ev = Lilac.__window__[:CustomEvent].new("lilac_doc_evt")
      doc.call(:dispatchEvent, ev)
    end
    fire.call
    Spec.assert_equal 1, hits

    # Unmount → the document-level listener must be removed (no leak).
    body[:innerHTML] = ""
    Lilac.flush_async!(16)
    fire.call
    Spec.assert_equal 1, hits
  end

  Spec.assert "window.on listener fires and auto-cleans on unmount" do
    doc = JS.global[:document]
    win = Lilac.__window__
    body = doc[:body]
    body[:innerHTML] = '<div data-component="dw-win"></div>'

    hits = 0
    klass = Class.new(Lilac::Component) do
      define_method(:setup) do
        window.on(:lilac_win_evt) { hits += 1 }
      end
    end
    Lilac.register "dw-win", klass
    Lilac.start

    fire = lambda do
      ev = win[:CustomEvent].new("lilac_win_evt")
      win.call(:dispatchEvent, ev)
    end
    fire.call
    Spec.assert_equal 1, hits

    body[:innerHTML] = ""
    Lilac.flush_async!(16)
    fire.call
    Spec.assert_equal 1, hits
  end
end
