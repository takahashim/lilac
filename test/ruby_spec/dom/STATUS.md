# DOM Polyfill — Session Progress Log

Multi-session master state for `test/ruby_spec/dom/`. Each session
appends a 3-7 line entry. See `/Users/maki/.claude/plans/polished-beaming-badger.md`
for the overall plan.

## Format

```
## Session N (YYYY-MM-DD): <one-line summary>
- Target spec(s): <files or "(foundation only)">
- Achieved: <what landed>
- Unlocked: <PURE_SPECS additions, or "none">
- Blocked by / open: <issues to address next session>
- Next: <recommended starting point for session N+1>
```

---

## Session 1 (2026-05-20): Foundation scaffolding

- Target spec(s): (foundation only)
- Achieved:
  - `nokogiri ~> 1.16` added to `cli/Gemfile` (development group)
  - `test/ruby_spec/dom/` scaffold: `world.rb` (Window proxy + namespace),
    `document.rb` (Document skeleton with `body`), `parser.rb`
    (`Nokogiri::HTML5.fragment` wrap), `dispatch.rb` (lookup table)
  - `mruby_wasm.rb` rewired: handle 1 (global) is now a
    `MrubyWasm::Dom::Window` instance; `js_get` / `js_set` / `js_call` /
    `js_new` fall through to duck-typed `__js_*__` methods on the
    handle value while keeping existing Hash/Array/JSON paths intact
  - `JS.global[:document]` returns a valid Document handle from inside
    wasm; `document[:body]` returns the body Element handle
- Unlocked: none (foundation)
- Blocked by / open: Element methods (innerHTML setter, querySelector,
  etc.) still no-op — session 2 targets
- Next: Session 2 — Element basic APIs (attributes, textContent,
  innerHTML get, children, parent, closest). No spec unlock expected.

## Session 2 (2026-05-21): Element read-side basics

- Target spec(s): (foundation only)
- Achieved:
  - `Element` moved into `test/ruby_spec/dom/element.rb`; `Document`
    now focuses on document ownership + node wrapper caching
  - `Document#wrap_node` added so repeated traversals reuse the same
    Ruby wrapper for a given Nokogiri node
  - `Element` now supports `children`, `parentElement`, `textContent`,
    `innerHTML` getter, plus `getAttribute` / `setAttribute` /
    `hasAttribute` / `closest`
  - Smoke-tested under `mise` Ruby (`3.4.1`) for attribute writes,
    parent identity reuse, and `closest("a[href]")`
- Unlocked: none (foundation)
- Blocked by / open: no mutation APIs yet (`innerHTML=` /
  `createElement` / `appendChild` / `insertBefore` / `cloneNode` /
  `classList`)
- Next: Session 3 — tree mutation primitives and classList, still
  without MutationObserver delivery.

## Session 3 (2026-05-21): Tree mutation primitives

- Target spec(s): (foundation only)
- Achieved:
  - `Document` now supports `createElement`, `createTextNode`,
    `querySelector`, and `querySelectorAll`
  - Added thin wrappers for `Fragment`, `TextNode`, `ClassList`, and
    `StyleDeclaration` in `test/ruby_spec/dom/element.rb`
  - `Element` now supports `innerHTML=` / `firstElementChild` /
    `tagName` / `classList` / `style` / template `content`
  - Mutation methods landed: `appendChild`, `insertBefore`,
    `removeChild`, `cloneNode`, `append`, `prepend`, `before`, `after`,
    `remove`, `replaceWith`, plus `removeAttribute` and
    `getAttributeNames`
  - Smoke-tested under `mise` Ruby (`3.4.1`) for selector lookup,
    fragment cloning, text-node append, sibling insertion, replace, and
    class toggling
- Unlocked: none (foundation)
- Blocked by / open: no `MutationObserver` delivery, no event system,
  and no callback bridge yet; component auto-mount / runtime directives
  still block on those
- Next: Session 4 — EventTarget / Event / listener registration, then
  callback bridge + scheduler so observer delivery can be wired in.

## Session 4 (2026-05-21): EventTarget and DOM events

- Target spec(s): (foundation only)
- Achieved:
  - Added `test/ruby_spec/dom/event.rb` with `EventTarget`,
    `Constructor`, `Event`, `CustomEvent`, `MouseEvent`, and
    `KeyboardEvent`
  - `js_new` in `mruby_wasm.rb` now honors duck-typed `__js_new__`,
    so DOM constructors can instantiate host-side event objects
  - `Window`, `Document`, and `Element` now support
    `addEventListener` / `removeEventListener` / `dispatchEvent`
  - `document.defaultView` now resolves to the host `Window`; window
    exposes `Event` / `CustomEvent` / `MouseEvent` / `KeyboardEvent`
    constructors
  - Bubbling dispatch now sets `target` / `currentTarget` and honors
    `preventDefault`, `stopPropagation`, and
    `stopImmediatePropagation`; `Element#click` dispatches a synthetic
    bubbling/cancelable click event
  - Smoke-tested under `mise` Ruby (`3.4.1`) for constructor creation,
    bubbling to parent listeners, `defaultPrevented`, custom `detail`,
    and listener removal
- Unlocked: none (foundation)
- Blocked by / open: wasm-side `JS.callback` still returns `0`, so
  runtime listeners from mruby cannot fire yet; scheduler and
  observer delivery are still absent
- Next: Session 5/6 boundary — callback bridge first (`js_make_callback`
  + invoke path), then scheduler/microtask drain so MutationObserver
  can deliver.

## Session 5 (2026-05-21): Callback bridge

- Target spec(s): (foundation only)
- Achieved:
  - Added `Dom::Callback` in `test/ruby_spec/dom/event.rb` so
    host-side callback wrappers can carry `__mruby_cb_id__` and route
    `.call(...)` back into the wasm VM
  - `js_make_callback` in `test/ruby_spec/mruby_wasm.rb` now returns a
    live callback wrapper instead of `0`
  - Added `MrubyWasm#invoke_callback(callback_id, args)` which
    allocates a temporary args handle, calls exported
    `js_invoke_proc(callback_id, args_handle)`, reads the returned Ruby
    value, and releases temporary host handles
  - Smoke-tested under `mise` Ruby (`3.4.1`) that
    `EventTarget#dispatchEvent` invokes `Dom::Callback` listeners and
    routes event args back into the host callback bridge
- Unlocked: none (foundation)
- Blocked by / open: full `vm.eval` confirmation is blocked locally by
  the existing `Wasmtime::Engine.new(wasm_exceptions: true)` /
  installed-gem mismatch outside the `cli` bundle path; scheduler,
  timers, and MutationObserver delivery are still absent
- Next: Session 6 — scheduler + microtask drain, then observer
  implementation on top of the now-live callback/event bridge.

## Session 6 (2026-05-21): Scheduler and end-to-end callback check

- Target spec(s): (foundation only)
- Achieved:
  - Added `test/ruby_spec/dom/scheduler.rb` with deterministic
    `setTimeout` / `clearTimeout`, `setInterval` / `clearInterval`,
    `requestAnimationFrame` / `cancelAnimationFrame`, and microtask
    queue support
  - `Window` now owns a scheduler and exposes timer/rAF methods through
    `JS.global.call(...)`; `MrubyWasm` now exposes host helpers
    `advance_time(ms)` and `drain_microtasks`
  - Installed the `cli` bundle under `mise` Ruby 3.4.1 and verified the
    local `~/git/wasmtime-rb` checkout is active for end-to-end checks
  - Fixed host-side boolean stringification in `mruby_wasm.rb` so
    wasm-side `js_bool` reads (`defaultPrevented`, `cancelable`,
    `dispatchEvent` return values) reflect host booleans correctly
  - End-to-end verified via `bundle exec ruby` that
    `JS.callback`-backed DOM listeners fire through `js_invoke_proc`,
    bubble with `target/currentTarget`, and mutate
    `defaultPrevented` as expected
- Unlocked: none (foundation)
- Blocked by / open: no `MutationObserver` implementation yet, no
  `Promise`/`.await` host drain yet, and no `JS.eval_javascript`
  emulation for `new Promise(r => setTimeout(...))` helper paths
- Next: Session 7 — MutationObserver on top of the live callback +
  scheduler bridge, then async/promise drain as needed.
