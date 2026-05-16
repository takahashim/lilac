# mruby-lilac

**Lilac** — signal-first component system for mruby on WebAssembly.

A small Ruby UI layer that connects existing HTML to Ruby state, events,
and DOM updates — without templating, virtual DOM, or component DSLs.

## Quick start

```html
<div data-component="counter">
  <button data-ref="increment">+</button>
  <span data-ref="count">0</span>
</div>
```

```ruby
class Counter < Lilac::Component
  def setup
    @count = signal(0)

    refs.increment.on(:click) do
      @count.update { |n| n + 1 }
    end

    bind refs.count, text: @count
  end
end

Lilac.register "counter", Counter
Lilac.start
```

See `docs/lilac-spec.md` in the repository root for the full spec,
and `docs/fetchy-spec.md` for the bundled HTTP client.
