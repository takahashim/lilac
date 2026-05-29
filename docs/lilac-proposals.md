# Lilac 検討中の提案

このドキュメントは Lilac の **未確定な設計提案** を記録する。確定判断は
[`adr/`](./adr/) 配下に ADR (1 判断 = 1 ファイル) として蓄積され、本 doc は
「これから議論する候補」を扱う。

両 doc の関係:

| doc | 内容 | 更新頻度 | 構成 |
|---|---|---|---|
| `adr/NNNN-*.md` | **確定** した設計判断の history (1 判断 = 1 ファイル)。覆された判断も `(superseded by ADR-NN)` として残す | 判断単位で追加、削除なし | ADR-0001 〜 ADR-NNNN |
| `lilac-proposals.md` (本 doc) | **未確定** の提案。議論で更新、却下なら削除、確定したら新 ADR として昇格して本 doc から消す | 任意のタイミングで編集 | テーマ別の節構成、番号なし |

設計原則と positioning は [`lilac-design.md`](./lilac-design.md) を参照。
各提案は原則 / 既存 ADR との関係を本文中で明示する。

## 提案エントリのフォーマット

各提案は以下のセクションで構成する(現状定着している慣行):

- **動機** — なぜこの提案が必要か。現状の摩擦、欠けている機能、矛盾点
- **提案** — 具体的に何を変えるか。HTML/Ruby の例で示す
- **利点** — 採用するとどう良くなるか
- **現状の workaround** — 採用しなくても回避できる方法(回避コストの提示)
- **実装的課題** — 採用したらどこに手が入るか
- **関連する確定判断**(任意) — 既存 ADR との関係(覆す / 補完する / 直交する)
- **ステータス** — 未判断 / 議論中 / 実装プロトタイプ中 等

提案が確定したら本 doc から削除し、新 ADR ファイルとして昇格させる。
**昇格時の operation**:

1. 本 doc から該当節を削除
2. `docs/adr/NNNN-slug.md` を新規作成 (NNNN = 4 桁 zero-padded、`# NNNN. Title` で始める)
3. ADR の中身を「判断 / 背景 / rationale / トレードオフ / 実装 / 後続作業 /
   ステータス」のフォーマットで記述
4. `docs/adr/README.md` の「ADR 一覧」テーブルに 1 行追加
5. 関連 spec doc(form-spec / directive-spec 等)にも反映
6. 覆された旧 ADR があればそのタイトル冒頭に `(superseded by ADR-NN)` を追加

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

未判断。将来 spec 拡張候補として記録のみ。実装着手するなら新 ADR ファイル
として昇格させる。

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

## Package .mrb の hot-reload (`lilac dev` 統合 or `lilac package-build --watch`)

### 動機

decisions §23 / §24 で package 配布形態が確立した結果、**package 作者の
dev loop** が明確に見えてきた:

- package source (`.rb`) を編集
- `lilac package-build` を手動で再実行 (面倒)
- example app の dev server をブラウザで手動 reload (さらに面倒)

iteration あたり ~10 秒のマニュアル作業 = package 開発体験が悪い。
公式 package (extras) でも第三者 package でも同じ摩擦。

利用者 (package を黒箱として使うアプリ作者) には影響なし — `.mrb` は
固定なので既存の `lilac dev` で足りる。

### 提案

3 案を検討した結果、**案 B (`package-build --watch`) を Phase 1**、
案 A (config 宣言) は需要が出てから Phase 2 として後追い。

#### 案 A — `lilac.config.rb` で package を宣言

```ruby
# example/lilac.config.rb
Lilac::CLI.configure do |c|
  c.packages = [
    { source: ["../src/package.rb"], output: "public/package.mrb" },
  ]
end
```

`lilac dev` 起動時に `watched_paths` を拡張し、package source 変更時に
`PackageBuild` を実行 → output 更新 → `live_reload.notify_all`。

長所: declarative、build pipeline が `lilac dev` に集約。
短所: Config の表面積拡大、アプリと package の関心混合。

#### 案 B — `lilac package-build --watch` 独立 daemon (Phase 1 推奨)

```sh
# Terminal 1
cd example && lilac dev

# Terminal 2
lilac package-build --watch ../src/package.rb -o example/public/package.mrb
```

`--watch` は `Listen` で source を監視、変更時に rebuild。`public/` は
既に `lilac dev` の watched_paths なので、`.mrb` 更新で自動 reload。

長所: dev_server.rb 変更 0、関心分離、CI / batch でも便利 (browser 不要)。
短所: 2 terminal 必要。

#### 案 C — `lilac dev --package SRC=OUT` flag

```sh
cd example && lilac dev --package ../src/package.rb=public/package.mrb
```

長所: flag 完結、context 明示。
短所: 複数 package で flag が増える。案 B と機能的同等で UX 劣る。

### 利点

- package 作者の dev loop が「save → reload」に短縮 (= 既存の Lilac dev
  UX と同じレベル)
- `--watch` は browser 不要のシナリオ (CI / 別ツール連携) でも便利
- `lilac dev` 本体の改修が不要 (案 B) → 小さい blast radius

### 現状の workaround

- 手動 `lilac package-build` の繰り返し
- shell の `fswatch` / `entr` で代用:
  ```sh
  fswatch -o src/package.rb | xargs -n1 -I{} \
    lilac package-build src/package.rb -o example/public/package.mrb
  ```
  動くが Lilac 標準で提供する方が discoverability が高い。

### 実装的課題

Phase 1 (案 B) — 規模 ~50 行 + テスト:

- `PackageBuild#watch(debounce:)` メソッド追加
  - 既存の `Watcher` (`cli/lib/lilac/cli/watcher.rb`) を再利用
  - 各 rebuild 失敗は stderr に出すだけで daemon は継続
- CLI 側に `--watch` flag 追加 (`command.rb` の `package_build_opts_parser`)
- 既存 `Watcher` を public API として確定(`require_relative "watcher"`
  を package_build.rb から)
- テスト: tempdir で input.rb を変更 → output.mrb の mtime が更新される

Phase 2 (案 A) — 需要次第:

- `Config#packages` を追加 (Settings に persistent な list)
- `DevServer#watched_paths` を拡張して package sources を含める
- 変更検知 dispatch を「app 系か package 系か」で分岐

### 関連する確定判断

- decisions §23 (package 機構 = runtime fallthrough)
- decisions §24 (package 配布形態 = mrb_load_irep / `boot({ plugins })`)
- §24.6 「後続作業」リストの "lilac dev で package .mrb 変更を即反映" が
  本提案の出発点

### ステータス

未判断 (proposal 段階)。本実装は router / async package 化が落ち着いた
後に検討。**Phase 1 (案 B) は実装規模が小さく、独立した価値があるため、
package が複数増えた段階で着手するのが妥当**。

## Dommy への JS 実行統合 — JS 依存テストの wasmtime-rb 移行

### 動機

Lilac のテストは現在 2 つの host で走る:

| runner | host | DOM | 役割 |
|---|---|---|---|
| `make test-wasm-rb` | wasmtime-rb | **Dommy**(Ruby 製 DOM polyfill) | 速い内ループ。`spec_runner.rb` の `PURE_SPECS` |
| `make test-node` | Node/V8 | happy-dom | CI。V8 でしか出ない bug(real JS callback / GC timing) |

調査で判明した現状(2026-05-29 時点):

- `runtime/*/wasm_spec/` の **71 ファイルは全て両 runner で走る**(PURE_SPECS = 全ファイル、除外ゼロ)。「Dommy が JS 不足で動かせない wasm_spec」は存在しない。
- Dommy は JS 非実行のため、async 系を **Ruby スタブで代替**している:`spec_runner.rb` の `drain_async!`、MutationObserver / Promise / setTimeout の擬似進行。`Lilac#flush_async!`(`runtime/mruby-lilac/mrblib/lilac.rb:95`)の `JS.eval_javascript("new Promise(r => setTimeout(r, N)).await")` もスタブ排水される。
- **Node 専用**なのは wasm_spec ではなく、JS ホスト統合テスト 2 本:
  - `test/parity-runner.mjs`(:full×:compiled DOM 一致)
  - `test/bundle-runtime.mjs`(ADR-0030 の boot 時 `fetch`→`<template>` 注入→mount)

  これらは mruby-wasm-js JS ブリッジ(`createVM`)+ `fetch` + `DOMParser` を必要とするため wasmtime-rb 経路に存在しない。

`dommy-js-quickjs`(Dommy に quickjs ベースの JS 実行を統合)が入ると、この棲み分けを縮められる。

### 提案

2 フェーズで JS 依存テストを wasmtime-rb 経路に寄せる。

**Phase 1 — async 忠実度の引き上げ(スタブ撤去)**
Dommy の async を Ruby スタブから **本物の quickjs イベントループ**に置換:
- `JS.eval_javascript` が実 JS を評価(`flush_async!` の Promise/setTimeout 排水が本物に)
- MutationObserver コールバックが real microtask で発火(data-each 行挿入・dynamic mount の検出が V8 と同じ順序)
- `spec_runner.rb` の `drain_async!` を「real event-loop drain」に縮退

効果:既存 71 spec が **より忠実**に走り、V8 でしか出なかった JS callback / microtask 順序 bug を Dommy でも捕捉。脆い手動 drain ロジックを削減。

**Phase 2 — JS ホスト統合テストの Dommy 版**
Dommy+quickjs が `fetch`(ローカル file 解決)と `DOMParser` を提供すれば、parity / bundle の **契約を Ruby spec として再表現**できる:
- bundle boot(`<link rel="lilac-bundle">` → fetch → template 注入 → mount/react)を wasmtime-rb 上で実行 → ADR-0030 の runtime テストが Node 非依存に
- :full×:compiled DOM 一致(parity)も同様に Dommy 化可能

注意:現行 `.mjs` ファイルがそのまま動くのではなく、JS ブリッジ(`createVM`)経由のドライブ部を wasmtime-rb ホスト向けに書き直す(wasm のホストは wasmtime-rb、DOM は Dommy、JS 評価は quickjs)。

### 利点

- **単一 runner で大半をカバー** — Node なし CI でも bundle/parity 契約を回せる
- **スタブ保守コスト減** — `drain_async!` 等の擬似進行を実イベントループで置換
- **忠実度向上** — async/MutationObserver が V8 相当の挙動に
- 内ループ(`make test-wasm-rb`)で JS 統合テストまで回せる

### 現状の workaround

現状維持(Node 経路を保持)。bundle/parity は `make test-node` 依存の
ままにし、async は Ruby スタブで近似する。動作はするが、(a) JS 統合契約が
Node 必須、(b) スタブと実 JS の乖離リスクが残る。

### 実装的課題

- **Dommy 側**:DOM mutation → quickjs microtask queue の配線、`fetch`
  (file/ローカル)・`DOMParser` の提供、timer(setTimeout/rAF)を quickjs
  イベントループに統合
- **spec_runner.rb**:`drain_async!` を real-loop drain に置換、JS 統合 spec
  用の DOM/fetch セットアップ
- **設計判断**:quickjs を mruby-wasm-js ブリッジ経由で通すか、Dommy 独自
  interop に閉じるか(前者ならブリッジ bug も Dommy で踏める)
- **テスト移植**:`bundle-runtime.mjs` / `parity-runner.mjs` の契約を Ruby
  spec 化(`fetch`/`DOMParser` 前提部分の置換)

### 残る Node 経路の価値(JS 実行でも埋まらない差分)

- **V8 固有 GC**(`FinalizationRegistry` timing)— quickjs ≠ V8。GC 依存の
  挙動確認用に最小限の Node smoke は残すのが妥当
- **mruby-wasm-js JS ブリッジ自体**の bug — Dommy が wasmtime-rb interop を
  使う限り Node でしか踏まない(quickjs をブリッジ経由にすれば別)

### 関連する確定判断

- [ADR-0030](./adr/0030-bundle-delivery-via-lilac-bundle-link.md) — bundle boot
  の runtime 契約。Phase 2 でこれを Dommy 化する対象
- [ADR-0029](./adr/0029-data-component-data-use-split.md) — data-use 展開。
  runtime spec は既に Dommy/Node 両方で green(`test_component_data_use.rb`)
- `Makefile` の `test-node` コメント(V8 固有 bug 捕捉の根拠)— 本提案が
  縮める対象だが、GC 差分のため完全置換はしない

### ステータス

実装プロトタイプ中(`dommy` + `dommy-js-quickjs` で JS 実行を整備中)。
本節は「JS 実行が入った後にどのテストを wasmtime-rb 経路へ寄せるか」の
計画。Phase 1(async 忠実度)は既存 spec の置換のみで影響範囲が局所的、
Phase 2(統合テスト移植)は fetch/DOMParser 提供が前提なので Phase 1 の後。
