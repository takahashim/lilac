# Lilac 検討中の提案

このドキュメントは Lilac の **未確定な設計提案** を記録する。確定判断は
[`lilac-decisions.md`](./lilac-decisions.md) 側に蓄積され、本 doc は
「これから議論する候補」を扱う。

両 doc の関係:

| doc | 内容 | 更新頻度 | 順序 |
|---|---|---|---|
| `lilac-decisions.md` | **確定** した設計判断の history。覆された判断も `(superseded by §N)` として残す | 月単位で追記、削除なし | §1〜§N の通し番号 |
| `lilac-proposals.md` (本 doc) | **未確定** の提案。議論で更新、却下なら削除、確定したら decisions.md §N+1 に昇格して本 doc から消す | 任意のタイミングで編集 | テーマ別の節構成、番号なし |

設計原則と positioning は [`lilac-design.md`](./lilac-design.md) を参照。
各提案は原則 / 既存判断との関係を本文中で明示する。

## 提案エントリのフォーマット

各提案は以下のセクションで構成する(現状定着している慣行):

- **動機** — なぜこの提案が必要か。現状の摩擦、欠けている機能、矛盾点
- **提案** — 具体的に何を変えるか。HTML/Ruby の例で示す
- **利点** — 採用するとどう良くなるか
- **現状の workaround** — 採用しなくても回避できる方法(回避コストの提示)
- **実装的課題** — 採用したらどこに手が入るか
- **関連する確定判断**(任意) — decisions.md の §N との関係(覆す / 補完する / 直交する)
- **ステータス** — 未判断 / 議論中 / 実装プロトタイプ中 等

提案が確定したら本 doc から削除し、`lilac-decisions.md` に新節として
追記。Appendix 年表にも追加。**昇格時の operation**:

1. 本 doc から該当節を削除
2. decisions.md の末尾に新 §N として追加(判断 / 背景 / rationale /
   トレードオフ の 4 節構成)
3. decisions.md の Appendix 年表に新行追加
4. 関連 spec doc(form-spec / directive-spec 等)にも反映
5. 覆された旧判断があれば `(superseded by §N)` をタイトル冒頭に追加

---

## `<template>` 透明ラッパ(inline 文脈の data-each / data-show)

### 動機

現状の `data-each` / `data-show` は対象 element 自身を container として
扱うため、**inline 文脈で余計な wrapper element が DOM に残る**:

```html
<!-- やりたい: <p> 直下に <strong> が並ぶ -->
<p>Tags: <strong>red</strong>, <strong>blue</strong>, <strong>green</strong>.</p>

<!-- 現状の書き方: <span> wrapper が常に残る -->
<p>Tags:
  <span data-each="@tags" data-key="id">
    <strong data-text="it.name"></strong>
  </span>.
</p>
```

同様に「条件付き inline 表示」(`<p>Hi<template data-show="@authed">, <strong>user</strong></template>!</p>` のような書き方)も現状は wrapper 必須。

### 提案

HTML5 `<template>` element の「content が main DOM tree に出ない」
セマンティクスを利用し、`<template data-each>` / `<template data-show>`
を **透明ラッパ** として扱う仕様拡張:

```html
<p>Tags:
  <template data-each="@tags" data-key="id">
    <strong data-text="it.name"></strong>
  </template>
.</p>
```

scanner 動作(案):
1. `<template data-each="...">` を発見
2. その content (DocumentFragment) を snapshot として保持
3. `<template>` 自身は anchor として残す(HTML 仕様で不可視)
4. 各 item に対して content を clone、`<template>` の **直前 sibling** として挿入
5. 結果: `<p>` の中に `<template>` (invisible) + 複数の `<strong>` が並ぶ

Vue (`<template v-for>` / `<template v-if>`) と同じ慣行。

### 利点

- inline 文脈で余計な wrapper が出ない(modern CSS の `display: contents`
  workaround より構造として綺麗)
- HTML5 標準の `<template>` セマンティクスに乗る
- Vue ユーザに親しみがある書き方
- 1 item = 複数 sibling 要素のパターン(`<dt>`/`<dd>` のペア等)も自然に書ける

### 現状の workaround

**inline 文脈では `<span>` wrapper で囲む**のが推奨:

```html
<!-- inline iteration -->
<p>Tags:
  <span data-each="@tags" data-key="id">
    <strong data-text="it.name"></strong>
  </span>.
</p>

<!-- inline 条件表示 -->
<p>Hi<span data-show="@authed">, <strong data-text="@username"></strong></span>!</p>
```

`<span>` は inline element なので block-level な見た目変化は無い。区切り
文字(`, ` 等)を入れたければ child の CSS で `:not(:last-child)::after { content: ", " }` 等で対応。「item 1個に複数 sibling 要素」が必要な場合は、その複数を別の inline element(`<span>` 等)で wrap して 1 root にまとめる、または `display: contents` を CSS 側で付与して wrapper の見た目影響を消す。

### 実装的課題

1. bind_list の anchor 管理(現状 container children を reconcile、透明
   モードでは template の前 sibling として挿入する別パス)
2. 1 item = 複数 sibling element のサポート(reconciler の key→nodes 管理)
3. ネスト時の動作(`<template data-each>` の中にさらに `<template data-show>`)
4. `<template>` content 内に `<div data-component="X">` が入る場合の MutationObserver マウント

### ステータス

未判断。将来 spec 拡張候補として記録のみ。実装着手するなら
`lilac-decisions.md` に新節 §N として「判断」を昇格させ、Appendix 年表に
追記する。

---

## 自動 microtask batching(effect / computed 再評価のスケジューリング)

### 動機

現状の Lilac は signal 更新が即座に下流 notify を起こす **同期 push**。
連続更新は明示的 `Lilac.batch { ... }` で bundle しないと effect が複数回走る:

```ruby
# 現状: effect が 2 回走る
@a.value = 1
@b.value = 2

# 望ましい: effect は次の microtask で 1 回だけ
Lilac.batch { @a.value = 1; @b.value = 2 }   # ← 利用者が書かないと駄目
```

Solid / Vue 3 / Svelte 5 は **自動 microtask batching** を採用しており、
同一 tick 内の複数 update は次の microtask で 1 回の effect run に bundle
される(明示 `batch` 不要)。

### 提案

`Signal#value=` の notify をすぐ走らせず、microtask キューに追加 + 同一
observer は dedupe。`queueMicrotask` 経由で flush:

```ruby
# 概念
def value=(new_value)
  return if equal_for_skip?(@value, new_value)
  @value = new_value
  @subs.each { |obs| Reactive.schedule(obs) }
end

# Reactive.schedule(obs):
#   - @pending に追加(同一 observer は dedupe)
#   - 初回追加時に queueMicrotask で flush 予約
```

### 利点

- ループ / 連続代入での過剰計算が消える(`100.times { @x.value += 1 }` で
  effect が 100 回ではなく 1 回)
- 利用者が `batch` を覚えなくて良くなる(認知負荷低下)
- modern reactivity の標準と整合

### 現状の workaround

- 利用者が `Lilac.batch { ... }` を明示的に使う(現状 spec で説明済み)
- 連続更新が稀なケースが多いので、実害はそこまで大きくない

### 実装的課題

1. `queueMicrotask` は `JS.global[:queueMicrotask]` 経由で呼ぶ必要あり
2. microtask flush 中に signal が更新された場合の挙動(再帰 schedule)
3. テストの assertion タイミング変化(`signal.value = x; expect(y)` が
   即時反映前提だと壊れる → microtask flush を await する API が要る)
4. error propagation: microtask 内の effect 例外をどう routing するか
5. 既存テスト 412 ケースのうち、即時反映前提のものが何件あるか調査が要る

### ステータス

未判断。実装する場合の優先度は高めだが、テスト書き換えコストとの兼ね合い
で計画が必要。**自動 batching 導入時は Lilac.batch を no-op 互換に残す**
ことで後方互換を保てる。

---

## Signal の `equals:` カスタム比較

### 動機

`Signal` は現状、primitive 型(`Numeric` / `Symbol` / `Bool` / `nil` /
`String`)のみ `==` で skip 判定し、それ以外(`Array` / `Hash` 等)は
**常に下流通知**する:

```ruby
@items = signal([])
@items.value = []   # ← 同じ空配列だが notify される(reference != identity)
```

Computed には `equals:` カスタム比較があるが、Signal にはない。

### 提案

```ruby
signal(initial, equals: nil)
# equals: false       → 常に通知(現在の Array/Hash 挙動の明示版)
# equals: ->(a, b) { ... } → カスタム比較
# equals: nil(default)→ 現状の primitive-only 自動 skip
```

### 利点

- `signal({user: {...}})` 等の hash signal で id 比較などにより不要な
  update を抑えられる
- Computed の `equals:` と API が揃う(直交した責務)
- React の `useMemo` の依存配列のような「変わったかどうか」制御が signal
  単位で可能

### 現状の workaround

- Hash/Array を signal にせず、内部値を primitive signal に分解
- Computed で wrap して `equals:` で skip

### 実装的課題

1. `Signal#initialize(initial, equals: nil)` の signature 拡張
2. `Signal#equal_for_skip?` の override を equals: 引数で受ける
3. `Signal#update { |v| ... }` も同じ equals 規約に従わせる
4. 既存 `signal(x)` 呼び出しは無変更で動く(default は現状維持)→
   後方互換 ◯

### ステータス

未判断。実装難度は低い(既存 Computed の equals: と同じパターンを
Signal にも適用するだけ)。実需が出てきた時点で着手で十分。

---

## Form と two-way binding の関係再整理 (Phase D 再評価)

### 動機

`lilac-decisions.md` §2 で「input/textarea/select の declarative bind は
form 経由が canonical、`data-value` / `data-checked` は廃止」と決めた。
理由は「同じことをやる 2 directive を維持する mental cost」「form 経由なら
validation / touched / dirty / error が ついで に得られる」だった。

しかし運用してみると、**コレクションの 1 要素としての input**(receipt の
行内 input、todo の編集モード、テーブルセル inline 編集 等)で form 経由が
unergonomic になることが分かった:

- 行ごとに `<form>` を入れるのは semantic に違和感(send button も submit
  もない)
- かといって親 form に全行の field を register すると、field 名が動的
  (`qty_1`, `qty_2`, ...) になり Symbol leak 規約(decisions §4)と衝突する
- 結局 `bind_input refs.X, @signal` の imperative escape hatch に逃げる
  しかなく、declarative-first の Lilac 方針(design.md §2.1)と齟齬

receipt example の bind_list → data-each 化作業
(2026-05-18, `examples/lilac-receipt.html`)で実際にこの摩擦が顕在化した。
form-spec §2 「現時点で非対応(将来検討): 動的 collection / field array」も
**この問題の自覚的な棚上げ** として記録されていた。

### 提案: signal / binding / form の 3 層に分解

現状の「form が field を所有、field が binding を持つ」という 2 層構造を、
**直交する 3 層**に再構成する:

```
signal     値そのもの (Signal / Computed)。現状通り、変更なし
  ↓ orthogonal
binding    signal ↔ DOM input の sync 機構。`<input data-bind="@qty">`
           で declarative に書ける。form と無関係に成立
  ↓ optional aggregation
form       既存の binding 群を集めて validation / submit / reset /
           base_error を提供。binding の **集約 layer** であり、binding
           それ自体ではない
```

具体案:

- **`data-bind="@ivar"` directive を導入**(Phase D で削除した `data-value`
  / `data-checked` のリバイバル + 統合版)。値は signal ivar のみ、input
  type に応じて value / checked / files 等を自動選択。form の有無は不問
- 既存の `<input data-field="qty">` は **form scope 内 binding の
  short-hand** として温存。`f.field :qty, ref:, initial:` 宣言は「signal
  を作って binding を貼って form に登録」の 3 ステップを 1 行でやる便利
  API という位置付けに
- form gem 側の **API 追加は不要**。`data-bind` で結線した signal を form の
  validation に乗せたい場合は、既存の `f.field :X, source: @X`
  (decisions §10) がそのまま使える(`Field#value_signal` を外部 Signal で
  hand-over する既存機構)。3 経路(`data-bind` 単独 / `f.field`+`data-field` /
  `f.field`+`source:`)で完全カバーされ、API surface 増加なし
- field array 問題は「field を `data-each` で動的に並べる」ではなく
  「各行を per-row 子 component で表現し、その component 内で `data-bind`
  + ローカル signal を持つ」として解決(行内に validation が要るときだけ
  各行で `f.field source:` を持つ)。さらに踏み込んで「item に Signal を
  nest して per-row component すら不要」という path もあり得るが、そちらは
  本提案の方針とは別軸(grammar 自体の `it.path` 廃止)を含むので独立提案
  として扱う。詳細は下記の
  [`it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill](#itpath-全廃--value-binding-bare-ident-scope--data-prop--auto-fill)
  を参照

利用者の判断基準:

| 必要なもの | 書き方 |
|---|---|
| DOM 結線だけ(form features 不要) | `data-bind="@X"` |
| form の validation/submit + 値が `<input>` 内 | `f.field :X` + `<input data-field="X">` |
| form の validation/submit + 値が `<input>` の外(子 component / 外部 signal) | `f.field :X, source: @X` |

### 利点

- 「form を使うべきか data-bind か」が **validation/submit の有無** 一問で
  決まる。現状の「form を使うべきか bind_input か」は経路が違いすぎて
  「両方覚えないと書けない」状態だった
- receipt の line-row が `<input data-bind="@qty">` で declarative に
  書ける(`bind_input` の imperative 記述が不要に)。`@ivar` のみ対応
  なので per-row 子 component (`LineRow`) は引き続き必要 — `data-each`
  の `it.field` を Signal として直接 bind したい場合は将来の it-path
  拡張を待つ
- form gem の責務が「validation / submit の orchestration」に純化し、
  「input ↔ signal の sync」という低レベル仕事は **`bind_input` / `data-bind`
  の共通レイヤ** に降りる(form は両者の薄い consumer)
- decisions §2 のトレードオフ節で挙げた「検索ボックスやトグルを form と
  呼ぶ違和感」も解消(`data-bind` で済む)
- form gem 側 API が増えない(`f.field source:` で外部 signal 借用は既に
  ある)。新規概念は `data-bind` directive 1 つだけ

### 現状の workaround

- 命令的 `bind_input refs.X, @signal` を使う(escape hatch として
  decisions §2 で明示的に残されている)
- 動的 collection 用には form gem 外で `signal([...])` + `data-each` +
  子 component の組合せ(form-spec §2 で推奨されている書き方)

いずれも declarative directive で書ける状態ではない。

### 実装的課題

1. `data-bind` directive の scanner 実装(input type 判別 + 双方向 sync
   effect 設置)。`bind_input` の thin wrapper として実装すれば本体ロジック
   は再利用可能
2. `data-bind` と `data-field` の同一 element 上の共存ルール(原則は
   conflict error、directive-spec §9.2.2 衝突ルールに追記)
3. CLI cross-ref linter の対応(`data-bind` の ivar 参照を component の
   `prop` / `signal` 宣言と突き合わせる新ルール)
4. decisions §2 を `(superseded by §N)` でマークし、新 § で「form は
   binding の集約 layer」と判断を明文化
5. 影響 spec: `lilac-form-spec.md` §1, §11.8, §12 / `lilac-directive-spec.md`
   §5, §6.2 / `lilac-design.md` §4.5
6. 例題への波及: `lilac-receipt.html` の per-row 子 component が不要に
   なる(行を `data-bind` 直接で書ける)。`lilac-form.html` は変更不要
   (form gem 経由のまま)

### 関連する確定判断 / 後続提案

- decisions §2 (Form を input bind の中心機構に) — 本案は §2 を
  **部分的に覆す**。「form 中心」ではなく「form は集約 layer」へ
- decisions §4 (Symbol leak 制約) — `data-bind` は ivar 参照なので
  Symbol leak 問題と無縁。動的 collection の Symbol 化問題を回避する
  経路として機能
- decisions §10 (stateful 子 input component の form 組み込み) — 子
  component を field 化する経路は維持。本案はそれと **直交** する新経路の
  追加
- form-spec §2 (将来検討: 動的 collection / field array) — 本案で
  「field array は不要、行ごとの `data-bind` で表現」という方針転換が
  可能に
- **proposals
  [`it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill](#itpath-全廃--value-binding-bare-ident-scope--data-prop--auto-fill)**
  (本 doc 内、後続提案) — 本案で導入される `data-bind` を起点に、grammar
  全体から path 構文を消す方向に発展。`data-bind` が `@ivar` のみ受け入れる
  という本案の制約は、後続提案で bare ident 形を受けるよう拡張される

### ステータス

scanner 実装 + wasm_spec(`test_directive_bind_runtime.rb`)+ receipt
example の data-bind 移行は完了(2026-05-18)。続いて後続提案
([`it.path` 全廃 ...](#itpath-全廃--value-binding-bare-ident-scope--data-prop--auto-fill))
により example はさらに簡素化(2026-05-19)。

`lilac-directive-spec.md` §3 / §5 / §6.2 / §8 に **data-bind directive と
form 統合 directive との関係** を反映済み(2026-05-19)。残りの未反映 spec
は `lilac-form-spec.md` §1, §11.8, §12(form gem 視点での data-bind 位置付
け)と `lilac-design.md` §4.5(「form を中心に据える代償」節の更新)。
これらと併せて確定判断 §15 への昇格を行う。

---

## Effect 内 `onCleanup` / per-run cleanup hook

### 動機

現状の Lilac `Effect` には **per-run の cleanup hook が無い**。リソース
(timer, subscription, websocket 等)を effect 内で確保する場合、次の
run 前にクリーンアップする手段が組み込みでは存在しない:

```ruby
# 現状: 解放のタイミングを effect ループ内で書きづらい
effect do
  id = JS.global.call(:setInterval, ..., 1000)
  # ↑ deps 変化で effect 再 run しても前回の interval が clear されない
end
```

Solid / Vue 3 / Svelte 5 は effect block 内で `onCleanup(() => ...)` を
declare できる:

```javascript
// Solid
createEffect(() => {
  const id = setInterval(...)
  onCleanup(() => clearInterval(id))    // 次回 run 前 + dispose 時に走る
})
```

### 提案

Lilac の `Effect#run` 内で `Lilac.cleanup_in_effect(&block)` のような
API を提供。effect クラス内に per-run cleanup リストを持ち、次回 run の
最初 + dispose 時に flush。

```ruby
effect do
  id = JS.global.call(:setInterval, ..., 1000)
  cleanup_in_effect { JS.global.call(:clearInterval, id) }
end
```

### 利点

- effect 内でリソース生成と解放が局所化される(現状は Component scope
  の `cleanup { }` でしか書けず、effect 再 run 時に解放されない)
- timer / websocket / DOM listener 等の管理が effect-self-contained に
- modern reactivity の標準パターンに整合

### 現状の workaround

- effect 内で生成した resource ID を ivar に保持し、次回 run の冒頭で
  明示 clear する(boilerplate 大)
- もしくは Component の `cleanup { }` で unmount 時のみ解放(re-run
  対応せず)

### 実装的課題

1. `Effect` クラスに per-run cleanup リスト追加
2. `Effect#run` 冒頭で前回の cleanup を flush、新規 deps tracking 開始
3. `Effect#dispose` でも cleanup flush
4. `cleanup_in_effect` のアクセス API:`Lilac.cleanup_in_effect { ... }`
   モジュール関数 / `Reactive.current.add_cleanup` / `Effect#cleanup(&block)`
   等の選択
5. nested effect での scope の正しさ(現在の Reactive.current が Effect
   なら、そこに add cleanup)

### ステータス

未判断。実装難度は中。利用者が timer / DOM listener を effect 内で扱う
具体的需要が出てきた時点で着手。当面は Component 全体の `cleanup { }` で
代替可能。

---

## `it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill

### 動機

`it.path` は Lilac directive grammar の中で **唯一の path 構文** で、他の
値(`@ivar` / bare identifier)とは別格の異物として浮いている。grammar
table を見ると:

| directive 種別 | 受け入れる値 |
|---|---|
| value-binding (data-text / data-bind / data-attr-* / ...) | `@ivar` / `it[.field]` ← path |
| data-each | `@ivar` / `it[.field]` ← path |
| data-class (key / value) | `@ivar` / `it[.field]` ← path |
| data-prop-* | `@ivar` / `it[.field]` / literal ← path |
| handler/scope (data-on-* / data-component / data-key / ...) | bare identifier |

`it.field` だけが dot 付き path で grammar の純度を崩している。HTML 内に
「コードを書かない」原則からすると、path 構文は最小限にしたい。

receipt example の bind_list → data-each → data-bind 移行作業
(2026-05-18, `examples/lilac-receipt.html`)を通じて per-row binding の
摩擦が再確認され、`it.path` 廃止の方向に複数 round の議論を経て収束した
(2026-05-19)。

検討して **却下された案**:
- `^field` 等の sigil — 視覚的に ugly
- `as id, name, ...` (destructuring) — code-like
- `data-each-fields` qualifier attribute — destructuring の別形
- `data-each-*` directive family — directive 数が倍増
- quoted literal (`data-prop-status="'todo'"`) — 視覚的に ugly
- 純粋な暗黙スコープ — 「スコープ可視性」が不足

### 提案

3 つの相互補完する変更を 1 セットで導入する。

#### Part 1: value-binding directive に bare ident を許す(data-each scope 内のみ)

対象 directive: `data-text` / `data-bind` / `data-attr-*` / `data-css-*` /
`data-show` / `data-hide` / `data-class`(key / value 両方)

- **data-each body 内**: bare ident = current iteration item の field 名
- **data-each scope 外**: bare ident は parse error(現状維持)
- `@ivar` = host component の signal(全 context で従来通り)

```html
<tbody data-each="@items">
  <tr>
    <td><input data-bind="description"></td>     <!-- bare = item field -->
    <td><input data-bind="qty"></td>
    <td data-text="line_total"></td>
    <td><button data-on-click="remove">×</button></td>  <!-- handler は従来通り method 名 -->
  </tr>
</tbody>
```

これは `data-key="id"` が既に行っている「iteration context での bare
ident = field 名」を value-binding directive にも拡張する形。

#### Part 2: data-prop-* は iteration field access を持たない(literal fallback は維持)

- `@ivar` → host signal value(従来通り)
- bare ident → literal(従来通り)
- `it.path` → **削除**
- bare ident を item field として解釈する経路は **持たない**(literal の
  解釈を優先)

```html
<!-- literal: 従来通り -->
<div data-component="KanbanColumn" data-prop-status="todo">

<!-- host ivar: 従来通り -->
<div data-component="X" data-prop-current="@msg">

<!-- iteration field 渡しは data-prop-X="it.Y" 経由ではなく Part 3 に委譲 -->
```

#### Part 3: data-each 直下の data-component は item から prop auto-fill

`data-component` 要素が `data-each` body に置かれている場合、child
component の `prop` 宣言は **item の同名 field から auto-init** される
(explicit `data-prop-X` で override 可)。

```ruby
class LineRow < Lilac::Component
  prop :id, Integer
  prop :description, String
  prop :qty, String
  prop :unit_price, String
  # data-each の中で mount されたら、各 prop が item の同名 key から auto-init
end
```

```html
<tbody data-each="@items">
  <tr data-component="LineRow">
    <!-- @id = item["id"]、@description = item["description"]、... auto -->
  </tr>
</tbody>
```

literal を混ぜたい場合:

```html
<tr data-component="LineRow" data-prop-mode="edit">
  <!-- @id / @description / ... は item から auto、@mode = "edit" literal で override -->
</tr>
```

**data-prop-* の lookup 順序**(child が `prop :X` を宣言している場合):
1. 同要素に `data-prop-X="..."` が明示されていればそれを使う
2. iteration context にあり item が key "X" を持てば `item["X"]` を使う
3. prop 宣言に `default:` があればそれを使う
4. else: required prop missing error

#### `it` / `it.field` の削除

`Value.parse` から `IT_PATH` を削除。移行期間中は両方 accept + dev_mode
で `it.*` 使用に対して warn、移行完了後は parse error 化。

### 利点

- **`it.path` 完全廃止**: grammar table から path 構文が消え、すべての
  directive 値が「**単一 identifier**(`@ivar` または bare ident)」に統一
- **新文法 / sigil / destructuring / quoted literal のいずれも追加なし**:
  「HTML 内にコードを書かない」原則と完全整合
- `data-key="id"` の既存慣行を value-binding directive にも自然に延長
- **per-row component pattern が軽くなる**: `data-prop-X="it.Y"` の forest
  が消え、child の prop 宣言が item interface の SSOT に
- **self-documenting**: child component の `prop :X` 宣言を読めば「この
  row component が item の何を使うか」が一目で分かる
- data-prop-* の literal fallback は無傷(`data-prop-status="todo"` 等の
  静的設定は無変更)

### 現状の workaround

- 現状は `it.field` の path 構文を使う(他に手段が無い)。directive
  grammar table 内で path 形式は `it.X` のみで、これが grammar の唯一の
  異物として認識されていた

### 実装的課題

1. **`Value.parse` に `BareIdent` を追加**: 識別子のみの値を新型
   `Value::BareIdent` として parse
2. **`Evaluator#read` の `BareIdent` 解決**: 現在 item の hash key を引く
   (item が nil または key 不在なら raise / dev_mode warn)
3. **value-binding 系 dispatch が `BareIdent` 受領**: dispatch_value_bind /
   dispatch_bind / dispatch_attr / dispatch_css / dispatch_visibility /
   dispatch_class の 6 経路を更新
4. **data-prop-* の dispatch は `BareIdent` を受領しない**: literal 解釈を
   優先するため `Value.parse` を経由しないか、`BareIdent` 結果を無視して
   literal fallback を走らせる
5. **Component mount in iteration context**: data-each の per-item block で
   child component を mount するとき、scanner が item を `Props.build` に
   渡し、`prop :X` 宣言ごとに「data-prop-X attribute が無ければ
   `item["X"]` を fallback として使う」ロジックを追加
6. **`it` / `it.field` の段階廃止**: 移行期は parser に `IT_PATH` を残し、
   dev_mode で `Lilac.logger.warn("data-X='it.Y' is deprecated; use bare
   ident or prop auto-fill")` を出す。**「Phase 完了」の判定基準**は
   以下 3 条件すべてが揃った時点:
   - (a) `examples/` 配下の全 `.html` から `it.path` 用法が消えている
     (`grep -rn 'it\.' examples/ | grep data-` で 0 件)
   - (b) `lilac-directive-spec.md` §3(値の文法)が `BareIdent` を
     canonical として記述しており、`it.path` は「(deprecated, removed
     in vN.M)」の歴史節としてのみ言及されている
   - (c) deprecation warning を出す minor version を最低 1 つ release し、
     利用者が手元コード migration に踏み切れる猶予期間(目安: 1 minor
     release ≈ 数ヶ月)を経ている

   3 条件達成後の次 minor version bump で `IT_PATH` を `Value.parse` から
   削除する。本提案が decisions §N に昇格する際、(c) の具体 version 番号
   (例: v0.13 で warn 開始、v0.14 で削除)を年表で固定する
7. **wasm_spec 追加**: bare ident in value-binding inside data-each /
   auto-fill on child component / data-each scope 外で bare ident が error
   になること / it.* 廃止後の error
8. **CLI cross-ref linter**: bare ident の field name は item schema が
   静的に分からないので soft warn 程度(host ivar 名との shadow チェックは
   可能)
9. **既存 example の migration**:
   - `examples/lilac-kanban.html`: `data-prop-id="it.id"` 等 → 削除、
     KanbanCard の prop 宣言 + auto-fill 経由
   - `examples/lilac-receipt.html`: 同様。LineRow も prop 経由で auto-fill、
     value-binding 内の bare ident 利用
   - `examples/lilac-todo.html` / `lilac-multipage.html`: data-prop-X="it.Y"
     を grep して機械置換
10. **spec doc 更新**:
    - `lilac-directive-spec.md` §3 (値の文法): `BareIdent` 形を追加、scope
      規則を明文化、§5 / §6 の各 directive 仕様で iteration context 内
      bare ident の意味を追記
    - `lilac-props-spec.md`: auto-fill 機構を新 § で記述、lookup priority
      を表で示す
    - `lilac-form-spec.md` §2 「将来検討: 動的 collection / field array」:
      本提案で per-row component の boilerplate が軽くなる旨を追記

### 関連する確定判断 / 既存提案

- **decisions §3** (directive 値の文法を厳格に保つ) — bare ident as field
  reference は identifier-only 原則の拡張で、原則とは整合。`it.path` 廃止
  により grammar table がより純粋に
- **decisions §12 / §14** (Props 機構) — Part 3 は Props auto-init の
  **source 種別を 1 つ追加**(現在は data-prop-X attribute のみ、本提案で
  iteration item も source に)。decisions §14 の「prop の意味拡張」と
  方向性が一致
- **decisions §11** (scanner one-pass + 2-phase processing) — Part 3 の
  auto-fill は phase A(field/button)の前に走る必要あり。scanner の処理
  順への追加点 1 つ
- **proposals 「Form と two-way binding の関係再整理」** — `data-bind`
  directive(その提案で導入)も本提案で bare ident 形を獲得
- **proposals 「data-bind の it-path 拡張」**(旧) — **本提案で吸収・置換**
  された(`it.path` 自体が廃止になるので、data-bind の it-path 対応は不要
  に。代わりに bare ident で書ける)

### ステータス

**実装完了 + spec 一部反映済み**(2026-05-19):

- runtime 実装: `Value::BareIdent` 追加、`Evaluator` / `Scanner` の dispatch
  拡張、`PropAutoFill` / `ItemField` モジュール抽出。`it.path` は両形 accept
  + dev_mode で deprecation warn を残しつつ段階廃止
- wasm_spec: `test_directive_bare_ident_runtime.rb`(bare ident 解決 /
  auto-fill / row reuse / scope 外 silent skip / it.path 互換+ warn の
  8 assertions)。既存 618 tests 全 pass
- example 移行: receipt / kanban / todo / search の `it.path` 用法を撤去
  (`data-prop-X="it.Y"` は auto-fill 経由に置換)
- spec 反映済み: `lilac-directive-spec.md` §3(BareIdent grammar)/ §5
  (directive 一覧)/ §6.2(`data-bind` 仕様)/ §8(衝突規則)、
  `lilac-props-spec.md` §7.5(`it.path` deprecation)/ §7.6(auto-fill 機構)
- 未反映 spec: `lilac-form-spec.md`(form gem 視点での data-bind / auto-fill
  の位置付け)、`lilac-design.md` §4.5

判断の論点(decisions §16 昇格時に再評価):

- **per-row component の auto-fill が implicit すぎないか**: receipt /
  kanban / todo / search で実装プロトタイプを動かした結果、reader にとって
  違和感は少なかった(prop 宣言が SSOT として機能、`data-prop-X="it.Y"`
  の forest が消える効果が大きい)
- **bare ident in value-binding directive の scope-context 依存**: 同じ
  `data-text="name"` が context によって解釈が変わる件は spec §3 で
  明文化済み。今のところ utility としての ergonomics 改善が違和感を上回る
- **`it` 互換期間の長さ**: 段階廃止の判定基準は本提案の「実装的課題 #6」
  に明示(example 移行 + spec canonical 化 + 1 minor release 以上の warn 期間)

残作業:
- form-spec / design.md の更新
- decisions §16 への昇格(本提案を「確定」化)+ Appendix 年表追記
- `IT_PATH` の最終削除は上記 3 条件が揃ってから次 minor release
