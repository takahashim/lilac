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

---

## `lilac build --target compiled` 統合(Vite 流の dev/prod 二段構え)

### 動機

`lilac-compiled.wasm`(mruby compiler / eval 抜きの最小 variant、現状 brotli
~168 KB)と `@takahashim/lilac-compiled` npm package(`boot({ bytecode })`
helper)は既に完成済みだが、**`lilac build` 側に `.mrb` 生成 path が無く**、
両者をつなぐ最後の 1 ピースが欠けている。`lilac build` の現状出力は dist
HTML に `<script type="text/ruby">` で source を埋め込み、`lilac-full.wasm`
で runtime `vm.evalScript()` する経路のみ。

production deploy 視点では:
- bundle size: full(brotli 247 KB)→ compiled(brotli 168 KB)で **−32%**
- 攻撃面: compiled は mruby parser を bundle しないので **runtime parser 由来の脆弱性** が消える
- mount cost: pre-compiled bytecode の load は source eval より速い

dev 体験視点では:
- 現状 `lilac dev` は wsv ベースの live reload で、`.lil` 編集 → SSE reload まで数十 ms。mrbc を kick すると 100-200 ms 追加。**dev は full、prod は compiled** で切り分けるのが妥当(Vite 流の dev/prod 二段構え)

`lilac build --target compiled` を実装することで、**user は同じ source で
"dev は速い、prod は小さい" を両立**できる。

### 提案: Vite 流の dev/prod 二段構え

```ruby
# lilac.config.rb
Lilac::CLI.configure do |c|
  c.dev_target   = :full       # lilac dev: full variant、source eval、mrbc 不要
  c.build_target = :compiled   # lilac build: compiled variant、.mrb 出力

  # mrbc の場所(未指定なら ENV["MRBC"] → ENV["MRUBY_WASM_RUNTIME_PATH"]
  # 下の build/host/bin/mrbc → $PATH の順で探索)
  # c.mrbc_path = "/path/to/mrbc"
end
```

#### Phase 1: `lilac build --target compiled`(最小実装)

1. **新規 `BytecodeBuilder` クラス**(`cli/lib/lilac/cli/bytecode_builder.rb`)
   - mrbc 探索ロジック
   - Ruby source の concat(codegen bindings + component class + `Lilac.start`)
   - subprocess で `mrbc -o dist/app.<hash>.mrb tmp.rb` 実行
   - error 時は mrbc stderr を `BuildError` に整形して raise

2. **`Builder` の target 分岐**
   - `:full`(現状): `<script type="text/ruby">` を dist HTML に埋め込み、
     `vm.evalScript("#ruby-source")` の boot 用 module script を inject
   - `:compiled`(新規): Ruby source は HTML に書かず、`.mrb` を dist に
     書き出し、`boot({ bytecode: fetch("./app.<hash>.mrb") })` の boot
     module script を inject

3. **Content-hash 付き `.mrb` filename**
   - `Digest::SHA256.hexdigest(bytecode_bytes)[0, 8]` で短縮 hash
   - filename: `app.<hash>.mrb`
   - cache busting: 内容変化で filename が変わる(Vite の慣行と同じ)

4. **`lilac-compiled.wasm` の vendor**
   - dist 出力先に `vendor/lilac-compiled.wasm`(または content-hash 付き)
     をコピー
   - dist HTML が import する `boot` helper 経由で wasm をロード
   - npm package 経由 (`@takahashim/lilac-compiled`) を import するか、
     `lilac-compiled.wasm` + `boot` helper を vendor 同梱するかは設定可能

5. **`dist/.lilac-manifest.json`**(Vite の `manifest.json` と同形式)
   - 論理名 → physical path のマッピング
   - 外部 framework integration から参照可能
   - 例:
     ```json
     {
       "app.mrb":            "app.a3f29b21.mrb",
       "wasm":               "vendor/lilac-compiled.wasm",
       "vendor-js":          "vendor/lilac-compiled/index.js"
     }
     ```

#### Phase 2: dev server の compiled モード(後続)

`c.dev_target = :compiled` の場合に `lilac dev` がやること:

- 起動時に初回 mrbc 実行 → `.mrb` 生成
- `Watcher` 経由で `.lil` / `.html` 変更検出
- 変更時に **mrbc 再実行** → `.mrb` 更新 → SSE で reload signal
- 既存 `Wsv::Server` + `/__lilac/livereload` SSE pub/sub の構造はそのまま
  (lilac dev は既に wsv backed なので、追加するのは mrbc invocation だけ)

mrbc 起動コストは ~100-200 ms。Vite の HMR ほど速くはないが、`lilac dev`
の SSE reload と同等の体感。**dev でも compiled flow の挙動を試したい**
利用者(scaffold で `--target compiled` を選んだ初日等)向け。

Phase 1 では `c.dev_target = :compiled` を error にし、Phase 2 で解禁する。

#### Phase 3: scaffold + docs

- `lilac new my-app --target compiled` で:
  - `lilac.config.rb` に `c.build_target = :compiled` をセット
  - `pages/index.html` の boot script を `boot({ bytecode })` 経路に
  - `README.md` を compiled flow 用に書き換え
- `docs/lilac-spec.md` の `lilac build` 章に target 分岐を追記
- `docs/lilac-decisions.md` の Appendix 年表に新 § を追加

#### サーバ backend: wsv 一本化

`lilac dev` の server backend は **wsv 一本化** を維持(現状の `DevServer`
が既に `Wsv::Server` 経由)。compiled target でも:

- 静的 file 配信(`.html` / `.wasm` / `.mrb` / `index.js` 等)= wsv のメイン
  機能
- SSE 経由 live reload = wsv の SSE primitive(`Wsv::Response::SseBuilder`)
  を借りて構築済み
- TLS(`--tls`)/ SPA fallback(`--spa`)/ CORS(`--cors`)等の wsv オプション
  は config で素通し設定できるよう拡張

別途 server library を追加する選択肢(Puma / Rack / Webrick)は採らない。
wsv は Lilac チームが書いた / Ruby stdlib only で zero-dep / TLS と SSE が
組み込まれていて、`make serve` でも既に使用中。**wsv 一本化** が運用コスト
最少。

### 利点

- **bundle size**: prod の brotli 247 KB → 168 KB(−32%)。React+ReactDOM
  並みのサイズで Lilac app を deploy できる
- **dev 速度を犠牲にしない**: `lilac dev` は full variant + source eval の
  まま、mrbc を kick しない。Vite の「dev は esbuild、prod は rollup」と
  同じ原理で **同一 source / 異なる artifact**
- **runtime parser 由来の攻撃面が消える**: prod に `mruby-compiler` /
  `mruby-eval` を bundle しないので、user 入力を Ruby として eval する経路
  が物理的に存在しない
- **cache 戦略**: content-hash 付き `.mrb` で browser cache が確実に
  invalidate される。長期 cache header(`Cache-Control: max-age=31536000,
  immutable`)を安全に付けられる
- **modern frontend tooling との familiarity**: Vite / esbuild ユーザに
  とって `target` config と manifest.json の存在が直感的
- **CLI codegen 経路の "本気の使い道" ができる**: 現状 `Lilac::Bindings::*`
  を emit する CLI codegen は `:auto` がデフォルトで recommended-only。
  compiled target ではこれが **唯一の経路**(runtime scanner 無し)になり、
  CLI codegen の価値が明確化

### 現状の workaround

- `lilac build` 後の dist HTML から `<script type="text/ruby">` を手作業で
  取り出し、`mrbc` で `.mrb` 化、HTML を手動編集 — 1 ページなら現実的だが
  複数ページ / 複数 component で運用にならない
- 別言語(`tools/build-compiled.rb` 等)で full な builder を再実装 — 重複
  メンテになる

いずれも片手間運用なので、`lilac build --target compiled` の native support
が欲しい。

### 実装的課題

1. **mrbc 探索ロジック**: `ENV["MRBC"]` → `ENV["MRUBY_WASM_RUNTIME_PATH"]/
   mruby/build/host/bin/mrbc` → `$PATH` 上の mrbc → 全部失敗で abort。
   doctor サブコマンドにも check を追加
2. **Ruby source の concat 順序**: `Lilac::Bindings::*` モジュール → user の
   component class → `Lilac.register` / `Lilac.start` 呼出し、の順を守ら
   ないと NameError。`Builder` の既存 emit 順を踏襲
3. **mrbc subprocess の error 整形**: stderr に source line 付きで出るので
   `at: SourceLocation.new(file: tmp.rb, line: N)` に詰め直して
   `BuildError` raise
4. **content-hash 計算 + filename rewrite**: `mrbc` 実行後の bytes を SHA256
   → 短縮 hash → rename → dist HTML 内の `fetch("./app.<hash>.mrb")`
   placeholder を書き換え
5. **wasm vendor 戦略**: 2 通り選べるように
   - (a) `vendor/lilac-compiled.wasm` を dist 出力に copy(self-contained
     deploy)
   - (b) `import { boot } from "@takahashim/lilac-compiled"` で npm 経由
     (CDN / npm registry に乗る、最小 dist)
   - config の `c.compiled_vendor_strategy = :copy | :npm` で切替
6. **manifest emission**: `dist/.lilac-manifest.json` を build 最後に書き
   出す。schema は Vite と同形式(`{ "logical-path": { "file": "actual-path",
   "src": "source-path" } }`)
7. **CLI test 追加**: 既存 `test_builder.rb` に target=:compiled の
   integration test を 1 case(mrbc を mock せず実呼び出し、ENV から path
   取得)
8. **Phase 2 の dev server 拡張**: `DevServer#rebuild` 内に mrbc invocation
   を加える。debounce window で連続変更を merge する既存 logic はそのまま
9. **既存 example の compiled-flow 対応確認**: kanban / receipt / todo /
   counter 等が compiled target でも動作することを wasm_spec / E2E test で
   parity 化(directive scanner が無い前提で codegen bindings が同じ DOM
   結果を出すこと)

### 関連する確定判断 / 既存提案

- **decisions §1**(Runtime canonical 化)— 本案は CLI を「optional な
  最適化 layer」として位置付けた §1 の方針と整合。dev は runtime canonical、
  prod は CLI codegen で最適化、という原案の延長
- **decisions §5**(HTML helper / bind_list legacy mode の廃止)— 本案で
  CLI codegen 経路の役割が明確化され、§5 で残した template node モード等
  の存在意義もより明瞭に
- **decisions §6**(CLI と runtime の lint severity 整合)— compiled target
  では CLI が canonical(runtime scanner 不在)になるので、cross-ref lint
  の severity がそのまま production gate になる

### ステータス

未判断。実装規模は中規模(本 doc 内 Phase 1 で ~620 行、Phase 2 / 3 含めて
~900 行)。判断の論点:

- **wasm vendor 戦略のデフォルト**: `:copy`(self-contained)か `:npm`
  (依存ベース)か。framework 想定利用者(Ruby 開発者で npm に馴染みが薄い
  ことを想定)を考えると `:copy` がデフォルト、`:npm` が opt-in
- **mrbc dependency の扱い**: `lilac-cli` gem が `wasi-sdk` / `mruby-wasm-
  runtime` への path を assume する現状を spec で固定するか、もう一段
  抽象化(mrbc を Ruby gem として配布等)するか
- **Phase 区切り**: Phase 1 だけで MVP として実用可能か、Phase 2 まで
  揃わないと release できないか。proposals doc 上は分離するが実装は同時
  でも可

Phase 1 の最小実装(receipt / counter 等で動作する compiled flow)を作って
動作確認 → 残作業の精度を上げてから判断昇格、という流れを推奨。

