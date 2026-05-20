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

## Session 7 (2026-05-21): MutationObserver childList delivery

- Target spec(s): (foundation only)
- Achieved:
  - Added `test/ruby_spec/dom/observer.rb` with
    `MutationObserver` and `MutationRecord`
  - `Window` now exposes a `MutationObserver` constructor; `Document`
    tracks registered observers and fan-outs `childList` mutation
    records through the scheduler's microtask queue
  - `Element` mutation paths now emit child-list notifications for
    `innerHTML=`, `appendChild`, `insertBefore`, `removeChild`,
    `append`, `prepend`, `before`, `after`, `remove`, and
    `replaceWith`
  - Added `nodeType` on element/text/fragment wrappers and
    `isConnected` on elements to satisfy registry / lifecycle checks
  - Smoke-tested under `mise` Ruby (`3.4.1`) that observer callbacks
    receive added/removed nodes after microtask drain
  - End-to-end verified via `bundle exec ruby` that
    `Lilac.start` + registry observer mounts a newly appended
    `data-component` element after `vm.drain_microtasks`
- Unlocked: none (foundation)
- Blocked by / open: no `Promise`/`.await` host drain yet, no
  `JS.eval_javascript("new Promise(r => setTimeout(...))")` emulation,
  and no router/history/storage/fetch surfaces yet
- Next: Session 8 — async/promise drain (or a minimal
  `JS.eval_javascript`/Promise carve-out) so DOM specs using
  `await setTimeout(0)` can be exercised directly.

## Session 8 (2026-05-21): Promise / await host bridge

- Target spec(s): (foundation only)
- Achieved:
  - Added `test/ruby_spec/dom/promise.rb` with host-side
    `Promise.resolve` / `Promise.reject`, `then`, `catch`, chained
    propagation, and `Error` value wrappers
  - `Window` now exposes `Promise`, `Error`, and `EventTarget`
    constructors; callback/constructor handles now report
    `typeof === "function"`
  - `js_eval` in `test/ruby_spec/mruby_wasm.rb` now recognizes a
    minimal async-oriented subset: `Promise.resolve(...)`,
    `new Promise(r => setTimeout(r, ms))`,
    `new Promise((resolve) => setTimeout(() => resolve(v), ms))`,
    `new Error(...)`, `new Event(...)`, `new EventTarget()`, plus basic
    object/array/string/number/boolean/null literals
  - End-to-end verified via `mise exec ruby@3.4.1 -- bundle exec ruby`
    that `Promise.resolve(...).await`, delayed `setTimeout` promise
    resolution, chained `.then`, object-literal promise payloads, and
    rejected promises through `JS::Error` all work
- Unlocked: none yet (async foundation; specs can now be exercised)
- Blocked by / open: `JS.eval_javascript` is still a carve-out rather
  than a general evaluator; router/history/storage/fetch remain absent
- Next: Session 9 — start pulling actual async-heavy Lilac specs
  through this bridge, or widen browser surfaces (`history`,
  `location`, `URL`, `storage`) based on the first failing group.

## Session 9 (2026-05-21): First DOM-touching spec unlock

- Target spec(s): `runtime/mruby-lilac/wasm_spec/test_directive_unsafe_html.rb`
- Achieved:
  - Added eval-time drain to `MrubyWasm#eval`: after `js_eval_handle`
    returns, calls `advance_time(0)` so any fiber suspended at `.await`
    (Promise + setTimeout(0)) resumes before control returns to the
    spec runner
  - Validated the full stack end-to-end:
    `body[:innerHTML]=` → `Lilac.start` → MutationObserver childList
    delivery → component setup + `bind_template_hook` → signal-driven
    `innerHTML` write → signal mutation triggers re-render
- Unlocked: **test_directive_unsafe_html.rb (1 assertion, 2 sub-asserts)**
  → PURE_SPECS = 13 (240 → 246 assertions)
- Blocked by / open: nothing new for this spec; the next sessions can
  start targeting the broader `directive_*` / `component_*` family
- Next: Session 10 — try `test_directive_text.rb` /
  `test_directive_attr.rb` (similar shape: small spec, single `.await`,
  signal-bound DOM mutation). If the same drain pattern works, batch
  several into one session.

## Session 10 (2026-05-21): Batch unlock — directive / component / bind / prop

- Target spec(s): directive_text/attr/class/show_hide (initial 4) —
  expanded mid-session after they all passed on first try
- Achieved:
  - All 4 initial targets passed with no polyfill changes — the
    Session 9 drain pattern + existing foundation cover them
  - Broadened to a probe pass of 26 candidate DOM specs (component,
    bind, prop, error_boundary, set_style, etc.)
  - **14 additional specs passed on first try**, batched into PURE_SPECS
  - 12 specs partially work or fail — recorded below for future sessions
- Unlocked (14 new spec files / +97 sub-assertions):
  - `test_directive_text` (2), `test_directive_attr` (2),
    `test_directive_class` (1), `test_directive_show_hide` (2),
    `test_directive_css` (2), `test_directive_on` (2)
  - `test_bind_attr` (3), `test_bind_template_hook` (4)
  - `test_component_mount` (7), `test_component_autoregister` (7),
    `test_component_nested` (4), `test_component_dynamic` (2)
  - `test_set_style` (4), `test_expose_lookup` (7),
    `test_error_boundary` (10), `test_prop_as_ivar` (11),
    `test_prop_ivar_override_detection` (5), `test_props` (18)

  PURE_SPECS: 13 → 31. assertions: 246 → ~340.

- Blocked by / open (12 specs not yet green; classified for future
  sessions):
  - `test_directive_each` (pass=0 fail=2) — list reconciliation,
    likely needs `data-each` directive + `bind_list` deeper coverage
  - `test_bind` (2/3), `test_bind_class_style` (2/3) — partial,
    likely classList edge cases or attribute observation order
  - `test_bind_input` (0/2) — `dispatchEvent(new Event("input"))`
    + two-way binding flow not exercised yet
  - `test_bind_list` (9/11) — mostly works; 2 list-reconciliation cases
    remain
  - `test_component_abort` (0 / 0) — async + AbortController flow;
    Promise drain semantics may not yet match
  - `test_component_timer` / `test_component_each_frame` (0 / 0) —
    timer / rAF observability through component lifecycle
  - `test_template` (16/19), `test_node_operations` (11/12) — small
    gaps in template + node ops APIs
  - `test_url_sanitizer` (3/4) — minor edge
  - `test_persistent_signal` (2/5) — needs `localStorage` polyfill
    (Session 15 in plan)
- Next: Session 11 — pick one of the partial-pass specs (likely
  `test_template` or `test_node_operations` since they're 1-3 asserts
  shy of green) and diagnose. Or batch the bind/* family if
  `test_bind` is a single shared cause.

## Session 11 (2026-05-21): Element reflected properties + attr name normalization

- Target spec(s): test_bind / test_bind_class_style / test_bind_input /
  test_url_sanitizer / test_template / test_node_operations /
  test_bind_list の diagnose & unlock
- Achieved (root causes uncovered):
  1. `set_attribute` / `get_attribute` / `has_attribute?` /
     `remove_attribute` を **lowercase 正規化** (HTML 属性名は browser
     DOM では大文字小文字無視で lowercase 保存される挙動に合わせる)
  2. Element の `__js_get__` に **反射プロパティ** 追加:
     - `hidden` / `disabled` / `checked` / `readOnly` / `multiple` /
       `required` → 対応属性の has-attribute boolean
     - `className` → `class` 属性の文字列
     - `id` / `value` → 同名属性の値
     - `readOnly` ↔ `readonly` の case mapping は
       `reflected_attr_name` helper で行う
  3. Element の `__js_set__` に **反射プロパティ書き込み** 追加:
     - boolean 群 → truthy なら空文字 attr、falsy なら removeAttribute
     - `className` / `id` / `value` → 対応属性へ書き込み
- Unlocked (4 new spec files):
  - `test_bind` (3 sub-asserts, 11 assertions) — boolean property
    bind が動くようになった
  - `test_bind_class_style` (2 sub-asserts) — `className` reader + 既存
    classList で確定
  - `test_bind_input` (2 sub-asserts) — `value` reader/writer 追加で
    DOM↔signal 双方向 bind が成立
  - `test_url_sanitizer` (4 sub-asserts) — case-insensitive 属性で `SRC`
    も sanitize ターゲットに乗る

  PURE_SPECS: 31 → 35. assertions: ~340 → ~370.

- Blocked by / open (per spec):
  - `test_template` (17/19): "bind_list with Template" — 2-arg block /
    managed template モードでの clone+mutate 期待挙動。Template の
    clone identity と reactive re-render の交点
  - `test_node_operations` (11/12): "Template#remove で template clone
    を auto-mount 経由で削除" — template tag の `.content` フラグメント
    clone → append → 再 auto-mount の経路。`MutationObserver` 内側で
    template clone の find_for_element までは到達できていない可能性
  - `test_bind_list` (9/11): list reconciliation の in-place update と
    reordering のノード identity 保持。bind_list ListReconciler の
    insertBefore/replaceChild が正しく既存ノードを動かしているかの検証
    が必要
  - `test_directive_each` (0/2): data-each / data-key directive。
    bind_list を内部で使うので、上の bind_list 問題と関連性あり
  - `test_persistent_signal` (2/5): `localStorage` polyfill 必要
    (plan session 15 ターゲット)
- Next: Session 12 — `test_bind_list` を起点に reconciler の node
  identity 問題を解明する。同根なら `test_directive_each` /
  `test_template` の bind_list 系も同時に取れる見込み。
  `test_node_operations` の Template#remove 問題は MutationObserver の
  detach 経路だけかもしれないので並行で確認可能。
