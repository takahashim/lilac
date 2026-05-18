# Lilac `data-*` directive 仕様 v0.12

文書は 6 つの Part に分かれる。Part 内は順序読みを想定、Part 間は独立して
参照可能。

| Part | 範囲 | 内容 |
|---|---|---|
| I — Foundation | Sections 1-3 | 設計哲学、ファイル形式、値の文法 |
| II — Directive Reference | Sections 4-6 | directive 一覧と個別仕様 |
| III — Cross-cutting Rules | Sections 7-10 | falsy 処理、合成、適用対象、error 階層 |
| IV — Build / Runtime Mechanics | Sections 11-13 | mount order、cross-ref lint、security |
| V — Patterns and Examples | Sections 14-17 | view model、escape hatch、完全例、既存 API |
| VI — Implementation | Sections 18-19 | 実装 phase、scope 外 |

---

## Part I — Foundation

設計哲学、ファイル形式、値の文法。spec 全体の前提となる基盤。

---

## 1. 設計哲学

### 1.1 Templates are configuration, not code

> **Templates are configuration, not code.**
>
> Ruby は dynamic 言語で、template に Ruby 式を書くと runtime fragility が
> 避けられない。Lilac の template は "Ruby を実行する場所" ではなく
> "static に解決可能な dispatch table" とする。

#### 1.1.1 「HTML 内にロジック禁止」徹底

具体的に何が禁止されるか、他フレームワークとの対比で示す:

| 禁止 | 例 | Lilac での代替 |
|---|---|---|
| inline event handler | `<button onclick="handler()">` | `data-on-click="m"` + Ruby method |
| expression in directive value | `data-text="@a + @b"` | `@sum = computed { @a.value + @b.value }` を Ruby 側で書き `data-text="@sum"` |
| ternary in template | `data-class="cond ? 'a' : 'b'"` | computed signal で結果を ivar 化 |
| method call with args | `data-text="format(@x)"` | `@formatted = computed { format(@x.value) }` |
| 比較 / boolean 演算 | `data-show="@count > 0"` | `@visible = computed { @count.value > 0 }` |
| string interpolation | `data-text='"hello #{@name}"'` | `@greeting = computed { "hello #{@name.value}" }` |
| inline JS scheme URL | `<a href="javascript:...">` | URL sanitizer で raise |

すべて **「ロジックは Ruby 側、HTML は identifier 参照のみ」** に変換
する規律。詳細な rationale(差別化 / メリット)は
[`docs/lilac-design.md`](./lilac-design.md) §2.2.1 参照。

### 1.2 系譜上の位置

| 系統 | 例 | template の式 | 検証 |
|---|---|---|---|
| Permissive Ruby | ERB, Slim, HAML, Phlex | 自由 (Ruby そのもの) | runtime |
| TS-typed reactive | Vue / Solid / Svelte + TS | 自由 (型で safe) | build 時 (TS) |
| **Fine-grained reactive + disciplined dispatch** | **Lilac** | **identifier のみ** | **build 時 (文法)、cross-ref は lint** |
| Disciplined dispatch | Stimulus, HTMX | identifier のみ | runtime (warn) |

Lilac は **Solid 系の fine-grained reactivity** を中核に置き、template 側を **Stimulus 系の規律ある dispatch 文化** で縛った framework。Vue/Solid の Ruby 移植ではない。

### 1.3 ブランド positioning

> "**Lilac templates are configuration, not code.**
> They reference signals (`@x`), iteration items (`it.x`), and methods
> (`method_name`) by name — and **nothing else**. No expressions, no
> method chains, no inline Ruby. All computation lives in your Ruby
> class as `signal`, `computed`, or `Data.define` view models.
>
> Vue / Solid / Svelte work great with TypeScript because TS verifies
> their template expressions. **Lilac is built for Ruby, where there
> is no TypeScript**, so we shipped something different: a template
> grammar small enough that grammar violations fail the build, and
> cross-references are linted at build time. **No template language
> means no template language to fail at runtime.**
>
> Logic lives in classes (where unit tests work). Templates are
> dispatch tables that the compiler checks."

### 1.4 設計選択 と philosophy の対応

各設計判断がどう哲学に対応しているかの SSOT 表。改訂時の self-check に使う。

| 設計選択 | この philosophy への整合 |
|---|---|
| `data-*` directive のみ (no `gn:`) | HTML 100% 標準、Stimulus 文化と地続き |
| identifier-only values | Ruby に型がないので template に式を持ち込まない |
| `@ivar` からの dot 不可 | signal の wrap/unwrap を runtime に伸ばさない |
| `it` からの 1 段 dot のみ | static 解決の保証範囲を明示 |
| `as` 句 / `=>` rightward / hash 形式の renaming を採用しない | Ruby 構文外 keyword の排除 |
| `data-each` の iteration var は `it` 固定 | block-param shadowing と一致 |
| **bang (`!`) 全 directive で禁止** | template 由来の副作用を許さない |
| `?` predicate は read だけ | read-only query は安全、handler 名としては typo 元 |
| `computed` / `Data.define` で view model 強制 | logic を Ruby class に集約 |
| method 名のみ `data-on-X` | dispatch-style (Stimulus 継承) |
| `data-value` / `data-checked` は **Phase D で削除済み** — input 双方向 bind は `data-field` + form 経由(form-spec §11) | form 抽象に統合、validation / touched / dirty が自動で得られる |
| `data-arg-X` は DOM data attribute 経由の string 渡し限定、reactive subscription API は提供しない | bind_list の stateless body 規律と整合、kanban 既存 pattern と互換、reactive 経路は `expose / lookup` 側に集約 |
| `data-class` の hash key は Ruby Hash syntax と同じ (bare は Ruby ident、kebab / 特殊文字は quoted) | Ruby grammar 借用を完全に貫く、変換 magic ゼロ、Vue/Solid/React classNames と同じ規約 |
| `RefElement` / `Template` に Turbo Streams 風の DOM 基本動詞 (`append` / `prepend` / `remove` / `replace_with` / `before` / `after`) を Ruby method として提供 | `method_missing` 経由でなく explicit な API、Ruby world で書ける範囲を広げ、`to_js` への escape を減らす |
| inline style 直書き (`data-style`) は提供せず、CSS variable 経由 (`data-css-X`) のみで動的値を渡す | styling rule の責務を CSS file に集約、style attribute injection の経路を文法レベルで遮断 |
| **URL 自動 sanitize (default ON)** | `javascript:` 等の XSS vector を block |
| **`data-attr-on*` / `srcdoc` / `style` build error** | 危険 attribute は構文レベルで遮断 |
| `data-unsafe-html` (scary name) | 意図的な opt-in を明示 |
| **build error と lint warning の明確な分離** | 完全検証を装わない |
| PascalCase + `::` for class | Ruby class 名直書き、翻訳ゼロ |
| nil → falsy 処理を Ruby 慣習で統一 | `if`/`unless` と同じ truthy/falsy |

→ **すべての設計判断が "Ruby は dynamic だから template を dumb に保つ" に収束**。

---

## 2. ファイル形式

### 2.1 `.lil` Single-File Component の構造

```html
<template>
  <!-- markup with data-* directives -->
</template>

<template data-template="name">
  <!-- (Optional) named sub-templates. Used via the runtime API
       `template(:name)` for manual cloning (modals, dynamic insertion).
       NOT used directly by directives — `data-each` inlines its body
       automatically. -->
</template>

<script type="text/ruby">
class MyComponent < Lilac::Component
  # state, methods, view models
end
</script>
```

### 2.2 `<template data-template="name">` (named template marker)

named template は **既存 Ruby API (`template(:name)`)** で参照する仕組み。
**directive とは独立** (`data-*` family ではなく element marker)。

```html
<template data-template="modal">
  <div data-component="Modal" class="modal">
    <button data-on-click="close">×</button>
  </div>
</template>

<template>
  <div data-component="App">
    <button data-on-click="open_modal">Open</button>
  </div>
</template>

<script type="text/ruby">
class Modal < Lilac::Component
  def close(_ev) = root.remove
end

class App < Lilac::Component
  def open_modal(_ev) = root.append(template(:modal))
end
</script>
```

named template の body 内に `data-component` を含められるので、template を
clone して append すると **MutationObserver による auto-mount** が動き、
`Modal#setup` (および `data-on-click="close"` の wiring) が自動で完了する。
parent は append のみ担当、close 処理は Modal 自身が知る形に
責務が分離される。

`root.append(template(:modal))` で App の root 要素配下に modal を
追加し、Modal は `root.remove` で自分を取り外す。`append` / `remove`
は `NodeOperations` module が `RefElement` / `Template` 双方に提供する
Turbo Streams 風の Ruby method (詳細は [Section 17 既存 API との関係](#17-既存-api-との関係)
参照)。**`root` の Ruby method で対称**になっている。modal を viewport
overlay にしたい場合は CSS の `position: fixed` で配置し、DOM の親子関係
とは独立に画面全体を覆える (`body` 直下への append が必要な高度なケースは
`JS.global[:document][:body]` への raw access で対応)。

`data-each` directive は **自身の body を inline 展開**するので、named
template とは関係なし。

---

## 3. 値の文法

すべての directive の値は **以下のいずれか** のみ。

### 文法定義

```
# Identifiers
ident          ::= [a-zA-Z_][a-zA-Z0-9_]* '?'?    # predicate `?` 許可、bang `!` 禁止
method_ident   ::= [a-zA-Z_][a-zA-Z0-9_]*         # event handler 名、suffix 一切なし
ref_ident      ::= [a-z_][a-zA-Z0-9_]*            # ref 名、lowercase 始まり、suffix なし
class_ident    ::= [A-Z][a-zA-Z0-9_]*             # Ruby class 名の 1 segment
key_field      ::= [a-zA-Z_][a-zA-Z0-9_]*         # data-key の field 名 (predicate `?` 不可)
ruby_hash_key  ::= [a-zA-Z_][a-zA-Z0-9_]*         # data-class の bare hash key (Ruby Hash の symbol literal 規則と同じ。kebab / `-` / 特殊文字は quoted form のみ)

# Value patterns
ivar           ::= '@' ident                      # @count, @todos
it_path        ::= 'it' ( '.' ident )?            # it, it.title, it.valid?
class_name     ::= class_ident ( '::' class_ident )*   # Counter, Admin::UserCard

# Hash literal (data-class only)
hash_literal   ::= '{' ( hash_entry (',' hash_entry)* )? '}'
hash_entry     ::= hash_key ':' hash_value
hash_value     ::= ivar | it_path

# hash_key は directive 別 (後述)
```

**bang (`!`) は全 directive で禁止**。

### 書けるもの

| 値 | 形式 |
|---|---|
| `@count` | ivar |
| `it` | iteration item |
| `it.title` | 1 段の attribute access |
| `it.valid?` | predicate (`?` 許可) |
| `increment` | method 名 (event handler) |
| `Counter` | class 名 |
| `Admin::UserCard` | namespaced class |
| `canvas` | ref 名 (lowercase) |
| `{ active: @is_active }` | hash literal (data-class 用) |

### 書けないもの (build error)

| 値 | NG 理由 |
|---|---|
| `@user.name` | ivar からの dot 禁止 |
| `it.user.name` | it からの dot は 1 段だけ |
| `it.title.upcase` | method chain |
| `it.save!` | bang は全 directive で禁止 |
| `save?` (data-on-X) | event handler に predicate suffix 不可 |
| `it.foo()` | parens / 引数 |
| `it.title.length > 5` | 比較演算子 |
| `!@flag` | 否定演算子 (`data-hide` を使う) |
| `"hi #{@name}"` | 文字列補間 |
| `@items[0]` | bracket subscription |

### Validator

build-time validator の実装 (Ruby 正規表現) は [Appendix A](#appendix-a-validator-regexp) 参照。

---

## Part II — Directive Reference

directive 一覧と各 directive の仕様。spec の中核。

---

## 4. Component 名 (`data-component`)

### 規則

- 値は **Ruby class 名そのもの** (PascalCase + `::`)
- 翻訳層なし、`Object.const_get(value)` で直接解決

### 例

```html
<div data-component="Counter"></div>
<div data-component="Admin::UserCard"></div>
```

```ruby
class Counter < Lilac::Component; end
class Admin::UserCard < Lilac::Component; end
```

---

## 5. Directive 一覧

| Directive | 値の型 | Build 後 (例) |
|---|---|---|
| `data-component="C"` | class_name | autoregister 経由 mount |
| `data-ref="x"` | ref_ident | explicit ref capture |
| `data-text="@s"` | ivar / it_path | `bind refs.gN, text: @s` |
| `data-unsafe-html="@s"` | ivar / it_path | `bind refs.gN, html: @s` |
| `data-show="@s"` | ivar / it_path | lil-hidden を falsy 時に付与 |
| `data-hide="@s"` | ivar / it_path | lil-hidden を truthy 時に付与 |
| `data-on-X="m"` | method_ident | `refs.gN.on(:X) { \|ev\| m(...) }` |
| `data-attr-X="@s"` | ivar / it_path | `bind refs.gN, attr: { "X" => @s }` |
| `data-arg-X="it.id"` | ivar / it_path (同要素に `data-component` 必須、**DOM 経由**) | `t.data(:X, it.id)` (子は `root.data(:X)` で読む。ivar に取れば snapshot、event 毎に読めば live) |
| `data-prop-X="..."` | literal / ivar / it_path (同要素に `data-component` 必須、子に `prop :X` 宣言が必要。`@ivar` / `it_path` の式解決は主に `data-each` 配下の row component 向け) | child の `@X` Signal を auto-init。子は `@X` / `props.X` / `instance.X` の 3 経路で値を読める。詳細 [`lilac-props-spec.md`](./lilac-props-spec.md) |
| `data-css-X="@s"` | ivar / it_path | `element.style.setProperty("--X", @s.to_s)` (CSS custom property 設定、`--` は自動 prepend) |
| `data-each="@c"` | ivar / it_path | `bind_list refs.gN, @c do \|it, t\| ... end` |
| `data-key="id"` | key_field (同要素に `data-each` 必須) | `key: ->(it) { it.id }` |
| `data-class="{a: @s}"` | hash_literal | `bind refs.gN, class: { "a" => @s }` |

### Form 統合 directive(別 spec 参照)

input / button の form 連携は **`docs/lilac-form-spec.md` Section 11** で
定義される独立の directive group:

| Directive | 役割 | 詳細 |
|---|---|---|
| `data-form="<name>"` | form scope 宣言 | [form-spec §11.2](./lilac-form-spec.md) |
| `data-field="<name>"` | field の UI 自動 wire | [form-spec §11.3](./lilac-form-spec.md) |
| `data-button="<name>"` | named action button | [form-spec §11.5](./lilac-form-spec.md) |

### 廃止された directive

以下は **Phase D で削除済み**(旧仕様の参考のため記載):

- `data-value="@s"` (ivar only) → form 経由 (`data-field`) に統合。汎用
  signal binding は命令的 `bind_input refs.X, @signal` を escape hatch
  として使う
- `data-checked="@s"` (ivar only) → 同上。checkbox/radio は
  `f.field :name, type: :checkbox` で form 経由

旧コードからの migration は form-spec §11.8 参照。

---

## 6. 各 directive の詳細仕様

Section 5 の table で表現しきれない規約 (引数規約・適用要素・grammar・lifecycle
等) を持つ directive のみ独立 subsection として記述する。`data-text` /
`data-unsafe-html` / `data-ref` / `data-attr-X` は Section 5 の table と
Section 7-10 の cross-cutting rules で必要十分なので独立 subsection を持たない。
`data-component` の規則は Section 4 を参照。

### 6.1 `data-on-X` の引数規約

**framework は常に固定 arity で呼び出す。user は要らない arg を `_` 名 or
splat (`*`) / default で受ける。codegen 側で arity 検査はしない**。

Ruby 通常メソッドは余分な引数を自動破棄しないので、`def m(item)` のみで
受けると `ArgumentError: wrong number of arguments (2 for 1)` になる。
user 側は **常に framework arity を満たす定義**にする必要がある。

| context | framework が渡す引数 | user の `def` の正しい形 |
|---|---|---|
| top-level (`data-each` 外) | `(event)` 1 個 | `def m(ev)` / `def m(_ev)` / `def m(*)` |
| `data-each` 内 | `(item, event)` 2 個 | `def m(item, ev)` / `def m(item, _ev)` / `def m(item, *)` / `def m(item, ev = nil)` |

NG 例:

```ruby
# ❌ data-each 内の handler を 1-arg で受ける → ArgumentError at runtime
def remove(item)
  @todos.update { |l| l - [item] }
end

# ✅ 第2引数を ignore する形で書く
def remove(item, _ev)
  @todos.update { |l| l - [item] }
end
```

### Build 後のコード

```ruby
# Top-level: data-on-click="increment"
refs.gN.on(:click) { |ev| increment(ev) }

# Inside data-each="@todos": data-on-click="remove"
bind_list refs.gN, @todos do |it, t|
  t.refs.gM.on(:click) { |ev| remove(it, ev) }
end
```

### user 側の def 例

```ruby
def increment(_ev) = @count.update(&:succ)
def remove(item, _ev) = @todos.update { |l| l - [item] }
def add_on_enter(ev) = add_todo(ev) if ev[:key].to_s == "Enter"
def add_todo(ev)
  ev.preventDefault
  ...
end
```

### 6.2 `data-value` / `data-checked` — **削除済み**(Phase D)

**ステータス**: Phase D で **削除**。CLI codegen / runtime scanner どちら
からも dispatch が消えており、HTML にこれらの属性を書いても **何も起き
ない**(普通の data-* 属性として残るが Lilac は無視)。新規 / 既存どちらの
code でも使わない。

旧仕様(歴史参照用):

| Directive | 適用要素 | 値の型 | 用途 |
|---|---|---|---|
| `data-value` | `<input>` (text 系), `<textarea>`, `<select>` | **`@ivar` のみ** (writable signal) | 双方向 text bind |
| `data-checked` | `<input type=checkbox>`, `<input type=radio>` | **`@ivar` のみ** (writable bool signal) | 双方向 boolean bind |

#### 廃止の理由

input/checkbox の declarative binding は **form 経由が canonical**(form-spec
§1, §11 参照)。`data-value` / `data-checked` の汎用 ivar binding は廃止し、
全 input binding を form の `f.field` + HTML の `data-field` に集約する。

理由:
- 「同じことをやる 2 つの directive」(`data-value` vs `data-field`)を
  維持する mental cost
- form 経由なら validation / touched / dirty / error が「ついで」に得られる
- single-input ケースも `form.field :query, initial: ""` の 1 行宣言で済む(form-spec §5)

#### Migration (旧 → 新)

```html
<!-- 旧 -->
<input data-value="@query">
<input type="checkbox" data-checked="@dark_mode">
```

```ruby
@query = signal("")
@dark_mode = signal(false)
```

→

```html
<!-- 新 -->
<input data-field="query">
<input type="checkbox" data-field="dark_mode">
```

```ruby
form.field :query, initial: ""
form.field :dark_mode, initial: false, type: :checkbox
```

`@query` / `@dark_mode` ivar は不要(値は `form[:query].value` /
`form[:dark_mode].value` で取れる)。

escape hatch として命令的 `bind_input refs.X, @signal` は残す(form を
通さず純粋に signal と input を bind したい advanced 用途用)。

#### iteration item の編集 UI

旧 spec で「`it_path` は read-only、編集は data-attr-checked + data-on-change で」
としていた pattern は引き続き有効。**read-only display + event handler** の
組合せ:

```html
<ul data-each="@todos">
  <li>
    <input type="checkbox"
           data-attr-checked="it.done"
           data-on-change="toggle_done">
    <span data-text="it.title"></span>
  </li>
</ul>
```

```ruby
def toggle_done(todo, _ev)
  @todos.update do |list|
    list.map { |t| t.id == todo.id ? t.with(done: !t.done) : t }
  end
end
```

### 6.3 `data-each` の key 規則

#### 配置と値

`data-key` は **`data-each` と同じ要素**に置く。値は iteration item の
**field 名 (bare identifier)** であり、`it.` prefix も `@` prefix も dot も含まない。

```html
<!-- ✅ correct (v0.12 form) -->
<ul data-each="@todos" data-key="id">
  <li data-class="{ done: it.done }">
    <span data-text="it.title"></span>
  </li>
</ul>
```

build 後の generated code:

```ruby
bind_list refs.gN, @todos, key: ->(it) { it.id } do |it, t|
  ...
end
```

#### 規則一覧

| 項目 | 規則 |
|---|---|
| `data-key` の配置 | **`data-each` と同じ要素** (それ以外は build error) |
| `data-key` の値 | `key_field` (bare ident, predicate `?` 不可) |
| `data-key` 指定 | **任意** (推奨) |
| 未指定時の fallback | `object_id` |
| 重複 key (runtime) | `Lilac.logger.warn` + 後勝ち |
| `data-each` あって `data-key` なし | **lint warning** (重複 risk のため明示推奨) |
| key 値の型 | `to_s` で stringify、`String#==` で比較 |

#### `data-key` で build error になるケース

| 値 | NG 理由 |
|---|---|
| `data-key="it.id"` | `it.` prefix 不可 (v0.11 までの形式)。`data-each` と同要素にいる時点で context は自明 |
| `data-key="@id"` | `@ivar` 不可 (iteration item の field を指す目的なので) |
| `data-key="user.id"` | dot access 不可 (1 段の field のみ。ネストが必要なら view model 側で flatten) |
| `data-key="id?"` | predicate `?` 不可 (boolean 値は key として collision しやすい) |
| `data-key` が `data-each` のない要素 | `data-key` は `data-each` への補足情報なので、`data-each` がない要素では bind_list が生成されず key も意味を持たない |

lint warning 文面 (data-key 未指定):

```
lilac: lint warning in todo_list.lil:23
  <ul data-each="@todos">

  `data-each` without `data-key` falls back to object_id, which may
  cause unstable re-renders when the list is rebuilt from raw data.
  Recommend:

      <ul data-each="@todos" data-key="id">
```

build error 文面 (旧形式):

```
lilac: build error in todo_list.lil:24
  <li data-key="it.id">
           ^^^^^^^^^^^
  `data-key` takes a bare field name, not an `it.` path.
  `data-key` must be on the same element as `data-each`.
  Move it to the data-each element and drop `it.`:

      <ul data-each="@todos" data-key="id">
        <li>...</li>
      </ul>
```

#### nested `data-each`

`data-each` の body の中にさらに `data-each` を置く形は **v0.12 では許可**
(build error にしない)。内側の `data-each` は外側とは独立した iteration
scope を持ち、`it` は内側 scope の item を指す (block-param shadowing)。

```html
<ul data-each="@categories" data-key="id">
  <li>
    <h3 data-text="it.name"></h3>
    <ul data-each="it.items" data-key="id">    <!-- inner each -->
      <li data-text="it.title"></li>            <!-- inner it -->
    </ul>
  </li>
</ul>
```

- 外側の `it` は内側 `data-each` の中ではアクセス不可 (shadowing)。
  外側の値を内側で参照したいなら parent 側 `Data.define` で flatten する
- ref scope も 1 段深く独立する (Section 9 「`data-ref` の scope」参照)

#### Empty state の canonical pattern

`data-each` は空配列に対して何も生成しないが、コンテナ要素 (`<ul>` 等)
自体は DOM に残る。「空のときは別 markup を出す」UI は、**list と empty
message を sibling として並べる**のが推奨形:

```html
<p data-show="@is_empty">No todos yet.</p>

<ul data-each="@todos" data-key="id">
  <li><span data-text="it.title"></span></li>
</ul>
```

`@is_empty` は computed で 1 箇所に定義する:

```ruby
@is_empty = computed { @todos.value.empty? }
```

`<ul>` 側に `data-hide="@is_empty"` を併記するかは任意 (空 `<ul>` を
非表示にしたい場合のみ)。冗長ではあるが、空 list が CSS margin を
残すなどの副作用を避けたい場合に有用。

#### `data-each` の中で子 component を使う

子 component への item 受け渡し、何を子に切り出すかの判断軸、`data-each` で
書きづらいケースの逃げ道は、すべて [Section 6.6 `data-arg-X`](#66-data-arg-x)
に集約 (SSOT)。最小限の例だけ示す:

```html
<ul data-each="@todos" data-key="id">
  <li data-component="TodoItem" data-arg-id="it.id"></li>
</ul>
```

### 6.4 `data-class` の hash key 文法

```
data-class-key ::= ruby_hash_key                  # bare: [a-zA-Z_][a-zA-Z0-9_]* (Ruby ident そのまま)
                 | '"' class_quoted_key '"'       # quoted: CSS class として valid な文字列
                 | "'" class_quoted_key "'"
class_quoted_key ::= [^\s\\'";\x00-\x1F\x7F]+     # whitespace / 制御文字 / quote / `;` 以外
```

**hash key は Ruby Hash literal と同じ規則**: bare で書けるのは Ruby ident
(`[a-zA-Z_][a-zA-Z0-9_]*`) のみ、kebab-case や特殊文字は quoted form 必須。
変換は一切しない (書いた通りに HTML class として出力)。

これは Vue / Solid / React の `classNames` 等と完全に同じ規約。

#### bare で書けるもの

Ruby ident と一致する class 名:

```html
<div data-class="{ active: @is_active, error: @has_error, loading: @is_loading }">
```

#### quoted が必要なもの

- **kebab-case** (Bootstrap / Tailwind の utility 等): `'btn-primary'`, `'is-active'`, `'text-center'`
- **BEM** (`__` + `--` 混在): `'card__title--large'`
- **Tailwind variant**: `'hover:bg-blue-500'`, `'md:text-lg'`
- **Tailwind arbitrary value**: `'top-[117px]'`, `'w-1/2'`, `'bg-[#bada55]'`
- **PascalCase / CSS Modules**: `'BtnPrimary'`, `'Button_button__1aBc2'`
- **数字始まり**: `'3d-effect'`
- **predicate `?` を含む** (CSS class としては実用にならないので非推奨): `'ready?'`

例:

```html
<!-- 典型: state は bare、CSS framework class は quoted -->
<button data-class="{ active: @is_active, disabled: @disabled, 'btn-primary': @primary }">

<!-- Tailwind: variant や arbitrary は quoted -->
<div data-class="{ 'hover:bg-blue-500': @hovering, 'md:text-lg': @desktop }">

<!-- BEM: 常に quoted -->
<li data-class="{ 'card__title--large': @show_large, 'is-selected': @selected }">
```

不正な key (whitespace / 制御文字 / `;` / quote 文字混入) は **build error**。

### 6.5 `data-show` / `data-hide` の予約 class

`lil-hidden` を予約。利用者の CSS で:

```css
.lil-hidden { display: none !important; }
```

scaffold が出す `pages/index.html` の `<style>` に default として inline で含める。

利用者が `lil-hidden` を自前で使うと衝突するため、build 時に検出:
- 利用者 CSS で `lil-hidden` という class 名を `data-class` で参照 → build warning ("`lil-hidden` is reserved by data-show/data-hide")
- 同要素に `data-show` と `data-class="{ 'lil-hidden': @x }"` 両方 → build error

### 6.6 `data-arg-X`

`data-arg-X` は parent → 子 component へ **DOM data attribute 経由で
string-level identity / config を渡す** directive。`data-component` 要素にあれば
valid で、`data-each` 専用ではない (静的 component 階層にも使える)。

#### 文法と attribute 名対応

```
data-arg-X の X     ::= [a-z][a-z0-9-]*      # HTML data-* attribute 名 (kebab 必須)
data-arg-X の値     ::= it_path | ivar
```

3 段の名前変換が発生する:

```
template            HTML                child Ruby
─────────────       ─────────────       ──────────────────
data-arg-id    →    data-id        →    root.data(:id)
data-arg-user-id →  data-user-id   →    root.data(:user_id)   # snake で書く
data-arg-status →   data-status    →    root.data(:status)
```

- template 上の `X` は **kebab-case** (HTML の data-* 慣習に合わせる)
- 子側は **snake_case** で読む (Lilac `RefElement#data` の `tr("_", "-")` 規則準拠)
- 仲介する HTML attribute は **kebab そのまま** (DevTools で確認可能)

dataset 相当の `element.dataset.userId` 経由ではなく、**`getAttribute("data-X")`
直読み**として実装される (Lilac `RefElement#data` の既存挙動と一致)。framework は
別途 "args table" を持たず、**親の DOM 要素の data-* attribute がそのまま
唯一の格納場所**。`<li data-id="42" data-status="todo">` として DevTools で
直接確認可能。

#### 用途は string-level identity / config 限定

文法上は `it_path` / `ivar` を受けるが、**設計意図は id / status / type tag /
mode flag 等の short string を渡すこと**に限定する。

| 用途 | 適否 |
|---|---|
| iteration item の id (`data-arg-id="it.id"`) | ⭕ canonical |
| status / type tag (`data-arg-status="it.status"`) | ⭕ |
| 親 signal の現在値 (`data-arg-mode="@mode"`) | ⭕ short config 用途のみ |
| Data instance / Hash / Array を丸ごと渡す | ❌ → `expose` / `lookup` |
| 大きな文字列、頻繁に変わる値 | ❌ → `expose` / `lookup` |

子で受けた値は **必ず string** (`to_s` 経由)。数値が必要なら子側で `.to_i` 変換。
複雑な data 本体は親が `expose :todos, @todos` で公開、子が `lookup(:todos)` で
引いて id 引きする。

#### lifecycle: DOM は live、ivar に取れば snapshot

`data-arg-X` の値が「いつ snapshot か」は、見ている対象によって変わる:

| レイヤ | 挙動 |
|---|---|
| 親 DOM の `data-X` attribute | **live**。bind_list の block 再実行のたびに書き換えられる (= 同 key で item の field が変わると DOM 上で新値に更新) |
| `root.data(:X)` API call | **read-on-demand**。`getAttribute("data-X")` で呼び出し時点の値を fresh に読む |
| 子の `@id = root.data(:id)` 等の ivar | **snapshot**。`setup` 1 回実行時の値を保持、以後 child が再代入しない限り不変 |

つまり「snapshot」なのは **child が ivar に取り込んだ値**であって、`data-arg-X`
directive 自体や `root.data(:X)` API は live。

**canonical pattern (snapshot を ivar に取る)**: identity / config 渡しの想定
用途では、子は `setup` で ivar に取り込むのが canonical。子の寿命内で値が
不変であるという mental model が成立し、bind_list の key-based diff (同 key
の child は remount されない) と整合する。

```ruby
class TodoItem < Lilac::Component
  def setup
    @id = root.data(:id)         # mount 時の snapshot
    @status = root.data(:status)
  end
end
```

**alternate pattern (event 発火時に最新値を読む)**: 「親が item の field を
更新したとき、子で最新値を使いたい」ケースでは、event handler の中で
`root.data(:X)` を呼び直すのが妥当。kanban の `KanbanCard` がこの形:

```ruby
class KanbanCard < Lilac::Component
  def setup
    root.on(:dragstart) do |event|
      id = root.data(:id)       # event 発火時の DOM 最新値を読む
      event[:dataTransfer].setData("text/plain", id)
    end
  end
end
```

bind_list が同 key で item を update した直後でも、次の event 発火時に最新値が
取得できる (DOM attribute は live なので)。

**reactive subscription API は提供しない**: 「`root.data(:X)` を signal
として wrap する API」「親の値変化を子で `computed` で追跡する API」は
v0.12 では提供しない。子の reactive な計算が必要なら:

- 親が `expose :todos, @todos` で signal を公開、子が `lookup(:todos)` で取得、
  `computed { lookup(:todos).value.find { |t| t.id == @id } }` で id 経由で追跡
- または `data-prop-X` ([`lilac-props-spec.md`](./lilac-props-spec.md)) で
  prop 値を渡す(`prop :X, Type` で auto-init される `@X` Signal で受け取る)

「`data-arg-X` は identity を **DOM 経由** で渡す。**reactive 経路は別建て** で、
signal を直接配線したいなら `expose / lookup`」が rule。

#### falsy 時の挙動

詳細は Section 7 「nil / falsy coercion ルール」参照。要点だけ:
**`nil` / `false` で HTML data attribute は削除**され、子の `root.data(:X)`
は `nil` を返す。

#### 制約 (build error)

要約 (詳細な error 文面と一覧は [Section 10](#10-build-error--lint-warning--runtime-warn-の境界) 参照):

- `data-component` のない要素では使えない (argument 渡しの相手がいないので)
- `X` の形は kebab-case のみ、`data-` prefix の二重は禁止
- 同名の static `data-X` / `data-attr-data-X` との同居は禁止 (DOM 上の唯一性)
- bang `!` / predicate `?` は値に使えない (Section 3 の `ident` 規則)

#### canonical pattern: `data-each` + 子 component

最も典型的な使い方は、`data-each` body 内の子 component に item identity を
渡すケース:

```html
<ul data-each="@todos" data-key="id">
  <li data-component="TodoItem" data-arg-id="it.id"></li>
</ul>
```

```ruby
class TodoList < Lilac::Component
  def setup
    @todos = signal(load_todos)
    expose :todos, @todos      # 子に data flow を開放
  end
end

class TodoItem < Lilac::Component
  def setup
    @id = root.data(:id)                                # identity
    todos = lookup(:todos)
    @todo = computed { todos.value.find { |t| t.id == @id } }
    bind refs.title, text: computed { @todo.value.title }
  end
end
```

**分離の意図**:

- **identity (id 等) は `data-arg-X` で HTML attribute 経由**: 1 段の string、
  bind_list の dispose & rebuild と矛盾しない、kanban demo と同形
- **データ本体は parent signal を `expose` / 子が `lookup`**: 子の computed が
  signal change に反応し、reactive 経路が成立
- **子 component は item を instance variable に持たない**: bind_list の lifecycle
  と整合 (Section 17 既存 API との関係 参照)

複数 argument を渡す例:

```html
<ul data-each="@todos" data-key="id">
  <li data-component="TodoItem"
      data-arg-id="it.id"
      data-arg-status="it.status"></li>
</ul>
```

```ruby
class TodoItem < Lilac::Component
  def setup
    @id = root.data(:id).to_i      # string → Integer は子の責任
    @status = root.data(:status)
  end
end
```

#### `data-prop-X` との関係

`data-prop-X` は [`lilac-props-spec.md`](./lilac-props-spec.md) で実装済み。
役割の住み分け:

| 機構 | 渡せるもの | 媒体 | reactive subscription | 採用 |
|---|---|---|---|---|
| `data-arg-X` | string | DOM data attribute (live, 子は `root.data(:X)` で read-on-demand) | **なし** — 子が ivar に取れば snapshot、event 毎に読み直せば live | 採用 |
| `data-prop-X` | string / `@ivar` / `it.field` を scalar 解決して child に渡す | child の `@X` Signal | 子の中で `@X` は普通の Signal、`computed { @X.value... }` で reactive 取得可。row reuse 時 parent が自動更新 | 採用 |

軽い identity 渡しなら `data-arg-X`、型付きの component prop として扱うなら
`data-prop-X` (+ `prop :X, Type` 宣言)。

#### 子 component を切り出す判断軸

`data-each` の body で子 component (`data-component` + `data-arg-X`) に
切り出すか、parent template に直接 `data-text` / `data-class` を書くかの
判断基準:

**子 component に切り出さない方が canonical**:

- item の field を表示するだけで、子に独自の state や lifecycle が要らない
- `Data.define` の view model で形を整えれば parent template で完結する

**子 component を使うべきケース**:

- 子に local UI state がある (`@dropdown_open = signal(false)` 等)
- 子が独自の event handler / lifecycle / cleanup を持つ
- 子を別の文脈でも reuse する想定

#### `data-each` で書きづらいケース → `bind_list` / `refs` に逃がす

以下は `data-each` + `data-arg-X` でも対応しきれず、`bind_list` + `refs`
直接操作に逃がすのが妥当:

- **行内 inline editing** — cell 単位で writable signal を独立管理する必要があり、
  iteration item の field 双方向 bind を禁止している (Section 6.2) 設計と噛み合わない
- **深くネストした mutable tree** — 子 component 切り出し + `expose` / `lookup`
  で対応できる範囲を超え、各階層に独立した sub-state が必要なケース
- **virtualization / windowing** — 全 item を DOM に描かない実装は
  `bind_list` の lifecycle を直接握る必要がある
- **drag & drop / item 並び替え中の中間状態** — DOM 位置と signal が
  一時的に乖離するケースは directive 経由だと表現が破綻する

判断基準: **「item の表示が変わるだけ」なら `data-each`、「item の identity
や DOM 配置に手を入れる」なら `bind_list` + `refs`**。

### 6.7 `data-css-X`

`data-css-X` は **CSS custom property (CSS variable) を反応的に設定する**
directive。inline style 全般を直接 binding せず、CSS variable 経由に
限定することで、styling rule の責務を CSS file に集約する設計。

#### 文法

```
data-css-X の X ::= [a-z][a-z0-9-]*       # CSS custom property 名 (kebab-lowercase、`--` は framework が自動 prepend)
data-css-X の値 ::= ivar | it_path
```

例:

```html
<div data-css-progress="@percent">
<div data-css-theme-color="@user_theme">
<div data-css-font-size="@base_size">
```

これらは runtime で `RefElement#set_style` (内部で `setProperty` / falsy 時は
`removeProperty`) を呼ぶ形にコンパイルされる:

```ruby
# data-css-progress="@percent" の build 結果
effect { refs.gN.set_style("--progress", @percent.value) }
```

#### 想定する使い方

CSS rule 側で `var(--X, default)` を参照し、JS は値だけ流し込む:

```css
.progress-bar {
  width: calc(var(--progress, 0) * 1%);
}
.themed {
  background: var(--theme-color, blue);
}
```

```html
<div class="progress-bar" data-css-progress="@percent">
<div class="themed" data-css-theme-color="@user_color">
```

style attribute を直書きさせない代わりに、**動的な値だけ CSS variable
経由で渡す**のが canonical pattern。

#### `data-style` directive は提供しない

**inline style を直接 binding する directive (`data-style`) は提供しない**
(恒久的な設計選択、Section 1.4 ブランド一致表参照)。styling rule は CSS
file に書き、動的な値だけ `data-css-X` で CSS variable に流す方針。

理由:

- **責務分離**: styling rule の宣言場所が CSS file に集約される
- **security**: inline style を介した CSS injection (`expression(...)` /
  `url(javascript:)` 等) の経路が文法レベルで存在しなくなる
- **CSP**: `style-src 'self'` を強くした際の互換性が良い
  (`setProperty` 経由は大半の CSP 設定で通る)
- **animation**: CSS variable は CSS の `transition` / `animation` で補間可能

連続値 (progress / slider / 動的色) はすべて CSS variable 経由で表現できる。
inline style の直接設定が必要なら `refs.x.set_style(property, value)`
(`RefElement#set_style`、falsy → `removeProperty`) を使う。さらに raw JS
API が必要な場合のみ `refs.x.to_js[:style]` で直接アクセスする。

**`data-css-X` vs `set_style` の使い分け**: template で reactive に書ける場面
(typical case) は `data-css-X` (declarative)、event handler / `effect` 内
など template syntax が使えない場面や、CSS variable 以外の標準 property
(`color`, `transform` 等) を直接設定したい場面は `RefElement#set_style`
(imperative)。

#### lifecycle

`data-css-X` は `effect` で値を購読する: 親 signal が変化するたびに DOM の
`setProperty` を呼び直す。**live binding** (snapshot ではない)。

- 値が `nil` / `false` (falsy) になったとき、`removeProperty` を呼んで
  CSS variable を削除。CSS 側の `var(--X, default)` の default に fallback
  ([Section 7](#7-nil--falsy-coercion-ルール) 参照)
- key が `removeProperty` された後、CSS rule 側で default を指定していない
  場合、その CSS variable を参照する property は値を失う

#### attribute 名の規則

- `X` は **kebab-lowercase** (`[a-z][a-z0-9-]*`)
- `--` は framework が自動 prepend (user は書かない)
- `data-css--theme-color` は build error (`-` 二重接頭)
- `data-css-Color` は build error (大文字含む)

#### 制約 (build error)

- `X` が kebab-lowercase 規則外 (大文字 / 先頭数字 / `_` 含む等)
- `X` が `data-` で始まる二重接頭
- 値が文法定義の `ivar` / `it_path` 以外
- 値に bang `!` / 比較演算子 / method chain 等を含む

#### 例: theming

```html
<template>
  <div data-component="App"
       data-css-theme-color="@theme_color"
       data-css-text-size="@text_size">
    <button class="btn">Themed button</button>
  </div>
</template>
```

```css
.btn {
  background: var(--theme-color, blue);
  font-size: var(--text-size, 1rem);
  color: white;
}
```

```ruby
class App < Lilac::Component
  def setup
    @theme_color = signal("teal")
    @text_size = signal("1.25rem")
  end
end
```

CSS variable は descendant に cascade するので、parent の `data-css-theme-color`
で子孫 全ての `.btn` の色が変わる。

#### 例: progress bar

```html
<div class="progress" data-css-progress="@percent"></div>
```

```css
.progress::before {
  content: "";
  display: block;
  height: 8px;
  width: calc(var(--progress, 0) * 1%);
  background: blue;
  transition: width 0.3s ease;
}
```

```ruby
@percent = signal(0)
# @percent.value = 75 で 75% まで滑らかにアニメーション
```

---

## Part III — Cross-cutting Rules

directive 横断のルール。falsy 処理、合成、適用対象、error 階層を扱う。

---

## 7. nil / falsy coercion ルール

signal/computed が `nil` や `false` を返した時の各 directive の挙動:

| Directive | nil / false の時 |
|---|---|
| `data-text` | textContent = `""` |
| `data-unsafe-html` | innerHTML = `""` |
| `data-value` | input.value = `""` |
| `data-checked` | checked = `false` |
| `data-attr-X` | **attribute 削除** (`removeAttribute`) |
| `data-arg-X` | **`data-X` attribute 削除** (`removeAttribute`、子の `root.data(:X)` は `nil` を返す) |
| `data-css-X` | **CSS variable 削除** (`removeProperty("--X")`、CSS の `var(--X, default)` の default に fallback) |
| `data-class="{ k: @s }"` (`@s` が falsy) | class **外す** |
| `data-show="@s"` | hidden (lil-hidden 付与) |
| `data-hide="@s"` | visible (lil-hidden 外す) |

### 規則

1. **truthy / falsy は Ruby の `if`/`unless` と同じ**: `nil` と `false` だけが falsy。`0`, `""`, `[]` は **truthy** (Vue/JS の慣習とは異なる、**Ruby 一貫性優先**)
2. **`data-attr-X` / `data-arg-X` / `data-css-X` で falsy → 属性/property 削除**: `data-attr-X` はアクセシビリティ整合 (`href=""` よりも href なしの方が「無効な link」として正しい)、`data-arg-X` は子の `root.data(:X)` が `nil` を返すことで「未指定」を表現、`data-css-X` は CSS の `var(--X, default)` の default fallback に integration
3. **`data-class` の hash value が falsy → その key (class 名) を class 属性から外す**: Vue/Solid と同じ慣習
4. **stringify が必要な場面では `.to_s`**: 非 nil/false の値は文字列化して使う

### `data-arg-X` の falsy 時の子側 idiom

`data-arg-X` が falsy になると attribute が削除され、子で:

```ruby
@id = root.data(:id)      # nil (attribute なし)
```

になります。child は `nil` を「未指定」として分岐に使えます:

```ruby
def setup
  @id = root.data(:id)
  if @id.nil?
    # まだ identity が確定していないケースの分岐
    return
  end
  todos = lookup(:todos)
  @todo = computed { todos.value.find { |t| t.id == @id.to_i } }
end
```

これにより `data-arg-id=""` (空文字、明示的に空 string を渡したい稀なケース)
と `data-arg-id` 自体が無い (nil) を区別可能。

---

## 8. 複数 directive 合成規則

### static 属性との合成

| 組合せ | 結果 |
|---|---|
| static `class="card"` + `data-class="{ active: @s }"` | `class="card active"` (union)、@s falsy なら `class="card"` |
| static `style="color: red"` + `data-css-theme-color="@c"` | static `style` はそのまま残る (CSS variable は別経路で設定されるので衝突しない) |
| static `value="x"` + `data-value="@s"` | data-value 優先 (initial value は signal で管理) |
| static `checked` + `data-checked="@s"` | data-checked 優先 |
| static `data-X="..."` + `data-arg-X="..."` 同名 X | **build error** (DOM data attribute は唯一の格納場所なので、二重宣言は意図不明) |
| static `data-X="..."` + `data-arg-Y="..."` 異名 (X ≠ Y) | OK (別 attribute) |

### directive 同士の衝突

| 組合せ | 規則 |
|---|---|
| `data-text` + `data-unsafe-html` | **build error** (両方が child content を奪い合う) |
| `data-text` + `data-each` | **build error** (each は children を生成、text は中身を上書き) |
| `data-show` + `data-hide` | **build error** (redundant, pick one) |
| `data-value` + `data-checked` | **build error** (form control の primary state は 1 つだけ) |
| `data-component` + `data-each` 同要素 | **build error** ("wrap with another element") |
| `data-component` + `data-ref` | OK (ref は mount root) |
| `data-component` + `data-show` / `data-hide` | OK |
| `data-component` + `data-on-X` | OK (root element の event) |
| `data-arg-X` + `data-attr-data-X` 同名 X (両方 `data-X` を書く) | **build error** (DOM attribute の二重 writer) |
| `data-arg-X` 同一 X を 1 要素に複数 | **build error** (HTML attribute の重複) |

### `lil-hidden` 衝突

- 利用者の static class に `lil-hidden` → **build warning** ("reserved class name")
- 利用者の `data-class` に `{ 'lil-hidden': @x }` + 同要素に `data-show`/`data-hide` → **build error**

---

## 9. directive の適用対象制約

各 directive が valid な要素種別:

| Directive | 許可要素 | build error |
|---|---|---|
| `data-component` | 任意要素 (1 要素に 1 つだけ) | 同要素に複数 `data-component` |
| `data-ref` | 任意要素 | 同 ref scope 内の重複 (下記参照) |
| `data-text` / `data-unsafe-html` | 任意要素 | (それ自体では error なし) |
| `data-value` | `<input type=text/email/url/password/number/date/...>`, `<textarea>`, `<select>` | それ以外 |
| `data-checked` | `<input type=checkbox>`, `<input type=radio>` | それ以外 |
| `data-show` / `data-hide` | 任意要素 | — |
| `data-on-X` | 任意要素 (event は bubble する) | — |
| `data-attr-X` | 任意要素 | banned attr names (後述) |
| `data-arg-X` | **`data-component` を持つ要素のみ** | `data-component` のない要素で使用、`X` が `data-` 始まり |
| `data-each` | 任意要素 | — |
| `data-key` | **`data-each` と同じ要素のみ** | `data-each` のない要素で使用 |
| `data-class` | 任意要素 | — |
| `data-css-X` | 任意要素 | `X` が kebab-lowercase 規則外、`data-` 二重接頭 |

build error 文面例:

```
lilac: build error in form.lil:8
  <div data-value="@email">
       ^^^^^^^^^^^^^^^^^^^
  data-value can only be used on form controls (input, textarea, select).
  Found on: <div>
```

### `data-ref` の scope (重複判定の単位)

ref name は **template scope ごと**に独立した namespace を持つ。`data-each`
の body はそれ自体が template scope なので、同名 ref を top-level と
item template に置いても衝突しない。

| Scope | 範囲 | 重複時 |
|---|---|---|
| **top-level scope** | component の `<template>` 直下 (data-each / 子 component 外) | **build error** |
| **item template scope** | `data-each` の body (各 iteration ごとに 1 つ) | **build error** (body 内重複時のみ) |
| **子 component scope** | `data-component="Child"` 配下は別 component の scope | 衝突しない |

例:

```html
<template>
  <div data-component="TodoList">
    <input data-ref="new_input">       <!-- top-level ref -->

    <ul data-each="@todos" data-key="id">
      <li>
        <button data-ref="remove_button" data-on-click="remove">×</button>
        <!-- item scope。top-level の new_input とは別 namespace -->
      </li>
    </ul>
  </div>
</template>
```

アクセス方法:

- **top-level ref**: `refs.new_input` (component instance から直接)
- **item ref**: `bind_list` の block 第 2 引数 (`t`) 経由で `t.refs.remove_button`
  (各 iteration ごとに別 instance)

build error になるのは:

- 同一 top-level scope 内で `data-ref="x"` が複数
- 同一 item template 内で `data-ref="x"` が複数 (1 つの `<li>` 直下に
  `data-ref="btn"` が 2 箇所等)

衝突しないのは:

- top-level の `data-ref="x"` と item template の `data-ref="x"`
- 別の `data-each` の item template 同士の同名 ref
- 親 component と子 component の同名 ref

nested `data-each` (Section 6.3 「nested `data-each`」参照) の場合も、
内側 `data-each` の body は 1 段深い独立 scope となる。

### `data-ref` 名と Ruby 標準 method の衝突

`refs.X` の form は `Refs#method_missing` 経由で `refs[X]` に解決される。
ただし `X` が **Ruby の Object / Kernel に既に定義された method 名**と
衝突する場合、Ruby のメソッド解決順位で先に既存 method がヒットし
**method_missing が呼ばれない**。private method の場合は `NoMethodError`
("private method called") になる:

```html
<!-- ❌ data-ref="p" は Kernel#p と衝突 -->
<p data-ref="p">hello</p>
```

```ruby
refs.p
# => NoMethodError: private method 'p' called for Lilac::Refs
```

衝突する典型的な名前 (Kernel / Object に存在する method):

- **出力系**: `p`, `puts`, `print`, `pp`, `format`, `sprintf`, `printf`
- **入力系**: `gets`, `getc`
- **制御**: `raise`, `throw`, `catch`, `fail`, `exit`, `abort`
- **関数**: `lambda`, `proc`, `method`, `methods`
- **内省**: `caller`, `inspect`, `class`, `send`, `public_send`, `tap`, `then`,
  `itself`, `nil?`, `frozen?`, `is_a?`, `kind_of?`, `respond_to?`, `object_id`,
  `hash`, `eql?`, `to_s`, `freeze`

#### 回避策

1. **意味のある名前を選ぶ** (推奨): 1 文字 ref はそもそも可読性が低いので、
   `paragraph` / `message` / `submit_btn` のような具体名を使う

   ```html
   <p data-ref="message">hello</p>   <!-- ✅ refs.message でアクセス可能 -->
   ```

2. **`refs[:name]` syntax を使う**: `[]` は明示 lookup で method_missing を
   bypass するので、衝突する名前でも参照可能

   ```ruby
   refs[:p]   # ✅ method_missing 経由でないので Kernel#p と衝突しない
   ```

ただし `[]` で逃げるよりも、**最初から衝突しない名前を選ぶ**方が読み手にも
親切。lint で警告するのが理想 (現状未実装、phase で追加候補)。

---

## 10. Build error / Lint warning / Runtime warn の境界

```
=== build error (停止、exit code 1) ===
- 文法違反:
  - @x.y (ivar 2 段 dot)
  - it.x.y (it 2 段 dot)
  - it.title.upcase (method chain)
  - !@flag, @a && @b, it.x + 1 (operators)
  - it.save!, save! (bang suffix)
  - save? (data-on-X の predicate suffix)
  - "hi #{@name}" (interpolation)
  - it.foo(), it[0] (parens / brackets)
- banned attribute:
  - data-attr-on* (use data-on-X)
  - data-attr-srcdoc
  - data-attr-style (CSS variable 経由で `data-css-X` を使う、または `refs.X.set_style(prop, val)`)
- 不正な class 名:
  - data-component="Counter" (PascalCase でない)
- directive 同居の衝突:
  - data-text + data-unsafe-html
  - data-each + data-component
  - data-show + data-hide
  - data-value + data-checked
- directive と要素種の不一致:
  - data-value on <div>
  - data-checked on <p>
  - data-key が data-each と別要素 (or data-each のない要素)
- data-key の値違反:
  - data-key="it.id" (it. prefix 不可、v0.11 までの形式)
  - data-key="@id" (ivar 不可)
  - data-key="user.id" (dot access 不可)
  - data-key="id?" (predicate 不可)
- data-arg-X の違反:
  - data-arg-X が data-component のない要素にある
  - data-arg-data-id="..." (X に `data-` prefix 二重)
  - data-arg-user_id / data-arg-userId (X は kebab-case のみ、snake / camelCase は build error)
  - 同名の static data-X + data-arg-X 同居 (e.g. `<li data-id="fb" data-arg-id="it.id">`)
  - 同名の data-attr-data-X + data-arg-X 同居 (e.g. `<li data-attr-data-id="@x" data-arg-id="it.id">`)
  - data-arg-X 同一 X が 1 要素に複数
- data-css-X の違反:
  - data-css-Color (大文字含む、kebab-lowercase 規則外)
  - data-css-3d-effect (数字始まり)
  - data-css--theme-color (X が `-` 二重接頭)
  - 同一 `X` の data-css-X が 1 要素に複数
- data-class の値違反:
  - bare key が Ruby ident 規則外 (kebab `btn-primary` 等は quoted form 必須)
  - quoted key に whitespace / 制御文字 / `;` / quote 文字混入
- 将来予約 directive の使用 (Section 19 参照):
  - (`data-prop-X` は実装済み — [`lilac-props-spec.md`](./lilac-props-spec.md) 参照)
- ref / class 衝突:
  - data-class に lil-hidden key + 同要素に data-show/hide

=== lint warning (build 通る、stderr で出力、--strict で error 化) ===
- @ivar が AST 抽出から見つからない (signal 宣言不明)
- def method_name が見つからない (handler 不明)
- it が data-each 外で参照されている
- data-each に data-key がない (重複 risk)
- 宣言済 signal / method が template から一度も参照されない (dead code)
- 利用者 CSS に lil-hidden 利用の疑い (static class name として detect)
- data-ref 名が Ruby 標準 method 名と衝突 (p / puts / class / send / inspect 等。
  refs.X 経由でアクセス不能になる。詳細は Section 9 「data-ref 名と Ruby 標準
  method の衝突」参照)

=== runtime warn (Lilac.logger.warn) ===
- 重複 key in data-each (key collision at runtime)
- Unsafe URL blocked (javascript:, vbscript:, data:text/html)
- signal の value が想定外の型 (e.g. text に Hash が来た)
- data-each で iteration item が nil
```

CLI:

```
lilac build              # 通常 (build error で停止、lint は warning)
lilac build --strict     # lint warning も error 化 (CI 推奨)
lilac doctor             # build せず lint だけ実行
```

---

## Part IV — Build / Runtime Mechanics

mount lifecycle (runtime)、cross-reference lint (build-time)、security
(runtime + build-time) の基盤メカニズム。

---

## 11. Mount order と refs 可用タイミング

```
mount sequence (post-order):
  1. parent の prepare_setup (pre-order, 子より前)
  2. 子コンポーネントを recursive に処理:
     a. 子の prepare_setup
     b. 子の setup (孫があれば孫が先)
     c. 子の directive bindings 適用
  3. parent の setup 本体実行
  4. parent の directive bindings 適用

setup 内で利用可能なもの:
  - refs.x          → 自分のテンプレート内の data-ref="x" 要素 (DOM)
  - refs.x.component → x が data-component の場合の子インスタンス (setup 完了済み)
  - 自分の @ivar    → setup 中に declare していれば

setup 中に NOT 利用可能なもの:
  - 自分の directive bindings (まだ適用されていない)
    → setup 中に refs.x の text を読んでも初期 HTML のままで、bind 後の値ではない

build-generated directive bindings の位置:
  → setup method の末尾に append される
  → effect / computed / signal の宣言が完了した後で起動するので、依存解決は正しい
```

これは現行 mruby-lilac 実装の挙動 (data-* directive 導入前から維持) と整合する。

---

## 12. Cross-reference lint

build tool は `<script type="text/ruby">` を **scanner で best-effort 解析**:

| 抽出パターン | 集合 |
|---|---|
| `@ivar = signal(...)` | declared_signals |
| `@ivar = computed { ... }` | declared_signals |
| `@ivar = resource(...)` | declared_signals |
| `@ivar = persistent_signal(...)` | declared_signals |
| `def method_name` | declared_methods |

scanner は完全な Ruby parser ではなく、**95% のケースをカバーする lint**。helper 経由、条件分岐内、別メソッド初期化等は false negative がありうる。

抽出した集合と template 内の identifier を照合し、見つからないものは **lint warning** として stderr に出力。

```
lilac: lint warning in counter.lil:7
  <span data-text="@unkown_signal"></span>

  Signal @unkown_signal is not declared via signal/computed/resource
  in Counter. Possible typo or dynamic declaration.
  Declared signals: @count, @doubled.
  Did you mean: @unknown_signal?
```

完全検証ではないので、**user が `--strict` を立てるか、`lilac doctor` を CI で回すか**で運用ポリシーを選ぶ。

---

## 13. Security Model

```
1. Safe by construction (大半の directive)
   ├─ data-text, data-value, data-checked, data-class,
   ├─ data-show, data-hide, data-on-X, data-arg-X, data-css-X,
   └─ data-each, data-key, data-ref, data-component

2. Auto-sanitized URL attributes (default ON, runtime)
   ├─ data-attr-href / src / action / formaction
   │  → javascript:, vbscript:, data:text/html を block
   │  → block 時は about:blank 置換 + Lilac.logger.warn
   └─ Opt-out なし (raw API での逃避は可)

3. Explicit opt-in via "unsafe" name
   └─ data-unsafe-html

4. Forbidden entirely (build error)
   ├─ data-attr-on*     (use data-on-X)
   ├─ data-attr-srcdoc  (use raw refs.X.to_js)
   └─ data-attr-style   (use data-css-X for CSS variables, or refs.X.set_style(prop, val))
```

### URL sanitizer

runtime で URL 系 attribute (`href` / `src` / `action` / `formaction`) に
対し、`javascript:` / `vbscript:` / `data:text/html` の dangerous protocol を
block し、`about:blank` で置換して `Lilac.logger.warn` を出す。実装は
[Appendix B](#appendix-b-runtime-security-実装) 参照。

### Build-time banned `data-attr-X`

`data-attr-on*` (任意 inline event handler attribute)、`data-attr-srcdoc`、
`data-attr-style` を build error にする regexp 検査。実装は
[Appendix B](#appendix-b-runtime-security-実装) 参照。

---

## Part V — Patterns and Examples

view model 規範、エスケープハッチ、完全例、既存 API との関係。spec から
canonical な書き方への橋渡し。

---

## 14. View Model 規範

「template に式を書かない」哲学の必然的な帰結として、**`Data.define` ベースの view model が事実上必須**。

### 例: 階層データの平坦化

```ruby
class TodoList < Lilac::Component
  TodoView = Data.define(:id, :title, :user_name, :due_str, :is_overdue)

  def setup
    @raw_todos = signal(load_todos)
    @todos = computed { @raw_todos.value.map { |t| view_of(t) } }
  end

  private

  def view_of(t)
    TodoView.new(
      id: t.id,
      title: t.title,
      user_name: t.user.name,
      due_str: t.due_at.strftime("%Y-%m-%d"),
      is_overdue: t.due_at < Time.now,
    )
  end
end
```

```html
<ul data-each="@todos" data-key="id">
  <li data-class="{ overdue: it.is_overdue }">
    <span data-text="it.title"></span>
    <span data-text="it.user_name"></span>
    <span data-text="it.due_str"></span>
  </li>
</ul>
```

### 例: `@ivar` の dot 不可 → computed で個別 ivar 化

```ruby
def setup
  @user = signal(load_user)
  @name = computed { @user.value.name }
  @avatar_url = computed { @user.value.profile.avatar_url }
end
```

```html
<h2 data-text="@name"></h2>
<img data-attr-src="@avatar_url">
```

---

## 15. エスケープハッチ

「これ template に書けないな」と思った時の判断フロー:

| やりたいこと | template で書く? | 解 |
|---|---|---|
| ネストデータ表示 | ❌ | view model + `Data.define` + `computed { ... .map }` |
| 文字列フォーマット | ❌ | `computed { "Hello, #{@name.value}!" }` |
| 比較 / filter | ❌ | `computed { @items.value.select { ... } }` |
| 否定 | ❌ | `data-hide` を使うか、`computed` で反転 |
| Hash key 参照 | ❌ | `computed { @h.value[:key] }` |
| iteration item の双方向 bind | ❌ | event handler 経由で `Data#with` |
| predicate | ⭕ | `Data` に `def valid?`、`data-show="it.valid?"` |
| 単純な値表示 | ⭕ | `data-text="@signal"` |
| dispatch | ⭕ | `data-on-click="method_name"` |
| 任意 attribute 設定 | ⭕ | `data-attr-X="@signal"` |
| DOM 基本操作 (append / remove 等) | — | `refs.x.append(other)` / `refs.x.remove` 等 (NodeOperations、Section 17 参照) |
| その他 DOM 操作 (escape) | — | `refs.x.to_js.setAttribute(...)` 等 raw JS API |

**「template に書けない」と思った時点で、必ず `computed` か `Data` で名前を付けてから template が参照する**。これが Lilac の中心哲学。

---

## 16. 完全な例

### Counter

```html
<template>
  <div data-component="Counter">
    <button data-on-click="decrement">-</button>
    <span data-text="@count">0</span>
    <button data-on-click="increment">+</button>
    <p data-class="{ negative: @is_negative }">Status</p>
  </div>
</template>

<script type="text/ruby">
class Counter < Lilac::Component
  def setup
    @count = signal(0)
    @is_negative = computed { @count.value < 0 }
  end

  def increment(_ev) = @count.update(&:succ)
  def decrement(_ev) = @count.update(&:pred)
end
</script>
```

### TodoList

```html
<template>
  <div data-component="TodoList">
    <h1 data-text="@title"></h1>

    <!-- 素の <form> = default scope。f.button :submit が submit を受ける -->
    <form>
      <input data-field="new_title" placeholder="What needs doing?">
      <button type="submit">Add</button>
    </form>

    <ul data-each="@todos" data-key="id">
      <li data-class="{ done: it.done }">
        <input type="checkbox"
               data-attr-checked="it.done"
               data-on-change="toggle_done">
        <span data-text="it.title"></span>
        <button data-on-click="remove">×</button>
      </li>
    </ul>

    <p data-text="@remaining_label"></p>
    <p data-show="@is_empty">No todos yet.</p>
  </div>
</template>

<script type="text/ruby">
class TodoList < Lilac::Component
  Todo = Data.define(:id, :title, :done)

  def setup
    @todos = signal([])
    @title = computed { "Todos (#{@todos.value.size})" }
    @remaining_label = computed { "Remaining: #{@todos.value.count { |t| !t.done }}" }
    @is_empty = computed { @todos.value.empty? }

    form do |f|
      f.field :new_title, initial: ""
      f.button :submit do |values|
        title = values[:new_title].strip
        next if title.empty?
        @todos.update { |l| l + [Todo.new(id: SecureRandom.uuid, title: title, done: false)] }
        form.reset
      end
    end
  end

  def toggle_done(todo, _ev)
    @todos.update do |list|
      list.map { |t| t.id == todo.id ? t.with(done: !t.done) : t }
    end
  end

  def remove(todo, _ev)
    @todos.update { |l| l - [todo] }
  end
end
</script>
```

---

## 17. 既存 API との関係

### 残る (明示派 / advanced 用途)

| API | 用途 |
|---|---|
| `data-ref="x"` | 明示 ref 名取得 |
| `refs.x.on(:click) { ... }` | 直接 event 設定 |
| `bind refs.x, text: @sig` | 直接 bind |
| `bind_list refs.x, @list do \|it, t\| ... end` | 直接 list bind |
| `effect { ... }` | 一般的 reactive 副作用 |
| `each_frame { ... }`, `timeout`, `every` | timer 系 |
| `expose / lookup` | 祖先 ↔ 子孫の任意距離通信 |
| `template(:name)` | named template の clone |
| `RefElement#append/prepend/before/after/remove/replace_with`, `Template#append/...` | Turbo Streams 風の DOM 基本操作 (NodeOperations mixin、引数は `RefElement` / `Template` / `JS::Object` / `String`) |
| `RefElement#set_style(property, value)` | inline style 設定 (falsy → `removeProperty`)。`data-style` 廃止後の canonical |
| `refs.x.to_js.setAttribute(...)` | raw DOM 操作 (上記 helper にない操作の escape hatch) |

→ **既存コードはそのまま動く**。directive を使わなければ既存挙動。

### 消える (user code から)

| 以前は書く必要があった | v0.12 以降 |
|---|---|
| `refs.x.on(:click) { ... }` | `data-on-click="method"` |
| `bind refs.x, text: @sig` | `data-text="@sig"` |
| `bind refs.x, class: { ... }` | `data-class="{ ... }"` |
| `bind_list refs.x, @list do ... end` | `data-each="@list"` |

→ 一般的 case で `bind` キーワードが **user code から消失**。

### 混在 OK

```html
<template>
  <div data-component="Mixed">
    <span data-text="@simple_signal"></span>
    <canvas data-ref="canvas"></canvas>
  </div>
</template>

<script type="text/ruby">
class Mixed < Lilac::Component
  def setup
    @simple_signal = signal("hello")
    ctx = refs.canvas.to_js[:getContext].call("2d")
    effect { ctx.fillRect(0, 0, @width.value, @height.value) }
  end
end
</script>
```

---

## Part VI — Implementation

実装 phase 計画と scope 外 (将来 phase) の予約事項。

---

## 18. 実装 Phase

| Phase | 内容 | 工数 |
|---|---|---|
| **7.6** | mruby-lilac: data-component PascalCase 受理 (kebab 廃止、autoregister 簡素化) | 半日 |
| **7.7** | lilac-cli: `data-on-X` + `data-text` (識別子検証、引数規約) | 半日 |
| **7.8** | `data-value` / `data-checked` / `data-unsafe-html` / `data-attr-X` (banned subset + URL sanitizer の runtime 組込み) | 1 日 |
| **7.9** | `data-class` (hash literal parser + Ruby Hash key 文法、quoted form 検証) | 半日 |
| **7.9b** | `data-css-X` (kebab-lowercase X 検証、`--` 自動 prepend、`RefElement#set_style` 経由で codegen — falsy 時の `removeProperty` も `set_style` が担保) | 1/4 日 |
| **7.10** | `data-show` / `data-hide` (`lil-hidden` 予約 class、scaffold CSS) | 1/4 日 |
| **7.11** | `data-each` + `data-key` (常に `it`, shadowing 対応, key fallback, lint) | 1 日 |
| **7.11b** | `data-arg-X` (`data-component` 要素のみ、`t.data(:X, value)` 経由 codegen、build error 検査) | 1/4 日 |
| **7.12** | nil/coercion ルール実装 (各 bind の falsy 経路) | 半日 |
| **7.13** | directive 合成規則 + 要素種別 build check | 半日 |
| **7.14** | **Cross-reference linter** (Section 12 の cross-reference lint を実装する tool。mruby AST scanning、親切な warning message) | 1 日 |
| **7.15** | docs 全更新 (philosophy 説明 + sample 全書き換え + scaffold template 更新 + security model 章) | 半日 |
| **合計** | | **約 6 日** |

各 phase は独立にコミット可能、途中で stop しても部分機能利用可。

---

## 19. スコープ外 (将来 phase で議論)

### Parent signal の継続追従 (`data-prop-X="@signal"` の signal 自動同期)

現状の `data-prop-X="@signal"` は **初回 mount 時 / row reuse 時の値だけ**
child の Signal に書き込む(parent の per-row scanner が触る 2 タイミング)。
parent の signal が他のタイミングで変化しても child には伝わらない。

P3 候補: parent の per-row scanner が `@parent_signal` を effect で watch し、
変化を `child.update_prop(:x, new_value)` で伝達。詳細は
[`lilac-props-spec.md` §11](./lilac-props-spec.md)。

### CLI codegen 経路での `data-prop-X` 値式

runtime canonical 経路では `data-prop-x="it.field"` / `data-prop-x="@ivar"` を
parent の Scanner が clone-time に解決するが、CLI codegen 経路では未対応。
CLI を経由して build するページでは `data-prop-X` の値は literal 限定。

将来対応: CLI codegen 側に同等の resolve コードを emit するか、CLI build に
lint warning を追加。

### その他

- `data-on-X` の codegen で `method.arity` を見た可変 dispatch (v0.12 では常に固定 arity、user が arity を合わせる規約)
- bytecode bundle (`.mrb` 出力)
- `<style scoped>` の CSS module 化
- `data-each` の `index` 暗黙変数
- Lifecycle hook 拡張 (`before_build`, `after_build`)
- RBS / Steep 統合 (将来 Ruby に型が普及した時)
- `data-unsafe-attr-href` 等の URL sanitize opt-out (現状の自動 sanitize で十分という判断)
- `--strict` mode の細かい挙動 (どの warning を error に昇格させるかの粒度設定)

---

## Appendix A: Validator regexp

Section 3 の EBNF に対応する build-time validator の実装 (Ruby 正規表現)。
spec 本体は EBNF を SSOT とし、本 appendix は実装側の参照。

```ruby
IDENT         = /[a-zA-Z_][a-zA-Z0-9_]*\??/     # predicate 許可、bang 禁止
METHOD_IDENT  = /[a-zA-Z_][a-zA-Z0-9_]*/        # event handler、suffix なし
REF_IDENT     = /[a-z_][a-zA-Z0-9_]*/           # ref 名、lowercase + 英数
CLASS_NAME    = /\A[A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*\z/
IVAR          = /\A@#{IDENT.source}\z/
IT_PATH       = /\Ait(\.#{IDENT.source})?\z/
READ_VALUE    = /\A(?:#{IVAR.source}|#{IT_PATH.source})\z/
```

EBNF と regexp の対応が divergent しないよう、Section 3 の文法改訂時には
本 appendix も同時更新する。

---

## Appendix B: Runtime security 実装

Section 13 の URL sanitizer / banned attribute 検査の実装。

### URL sanitizer (runtime, mruby-lilac 側)

```ruby
URL_ATTRIBUTES = %w[href src action formaction].freeze
DANGEROUS_PROTOCOL = /\A\s*(javascript:|vbscript:|data:text\/html)/i

def apply_attr(el, name, value)
  str = value.to_s
  if URL_ATTRIBUTES.include?(name.to_s.downcase) && DANGEROUS_PROTOCOL.match?(str)
    Lilac.logger.warn(
      "Unsafe URL blocked for #{name.inspect}: #{str[0, 80].inspect}",
    )
    el.call(:setAttribute, name, "about:blank")
    return
  end
  el.call(:setAttribute, name, str)
end
```

### Build-time banned `data-attr-X`

```ruby
BANNED_ATTR_NAMES = /\Aon[a-z]+\z|\Asrcdoc\z|\Astyle\z/
```
