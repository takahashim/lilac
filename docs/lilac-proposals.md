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
(2026-05-18, `examples/runtime-only/lilac-receipt.html`)で実際にこの摩擦が顕在化した。
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
  nest して per-row component すら不要」という path は別軸の grammar 判断
  ([`lilac-decisions.md` §16](./lilac-decisions.md))として確定済み

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
- decisions §16 の bare ident 拡張(`data-bind="qty"` で iteration item の
  Signal field を bind)と組み合わせると、per-row component なしでも
  data-each 内 input の two-way binding が書ける

### 現状の workaround

- 命令的 `bind_input refs.X, @signal` を使う(escape hatch として
  decisions §2 で明示的に残されている)
- 動的 collection 用には form gem 外で `signal([...])` + `data-each` +
  子 component の組合せ(form-spec §2 で推奨されている書き方)

いずれも declarative directive で書ける状態ではない。

### 関連する確定判断 / 後続提案

- decisions §2 (Form を input bind の中心機構に) — 本案は §2 を
  **部分的に覆す**。「form 中心」ではなく「form は集約 layer」へ
- decisions §4 (Symbol leak 制約) — `data-bind` は ivar 参照なので
  Symbol leak 問題と無縁
- decisions §10 (stateful 子 input component の form 組み込み) — 子
  component を field 化する経路は維持。本案はそれと **直交** する新経路の
  追加
- decisions §16 (`it.path` 全廃 + value-binding bare-ident scope) — 本案で
  導入された `data-bind` を起点に、grammar 全体から path 構文を消す方向に
  発展した(`data-bind` は §16 で bare ident 形も受けるよう拡張済み)
- form-spec §2 (将来検討: 動的 collection / field array) — 本案で
  「field array は不要、行ごとの `data-bind` で表現」という方針転換が
  可能に

### ステータス

scanner 実装 + wasm_spec(`test_directive_bind_runtime.rb`)+ receipt
example の data-bind 移行は完了(2026-05-18)。decisions §16 の bare ident
拡張で example はさらに簡素化(2026-05-19)。

`lilac-directive-spec.md` §3 / §5 / §6.2 / §8 に **data-bind directive と
form 統合 directive との関係** を反映済み(2026-05-19)。残りの未反映 spec
は `lilac-form-spec.md` §1, §11.8, §12(form gem 視点での data-bind 位置付
け)と `lilac-design.md` §4.5(「form を中心に据える代償」節の更新)。
これらと併せて確定判断への昇格を行う。

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

