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
