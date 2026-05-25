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

## `lilac-wasm-bin` gem: rubygems で `lilac build` まで完結させる

### 動機

`lilac-cli` を `gem install` しただけでは `lilac build`(default
`--target compiled`)が動かない。必要物 3 種が外部依存:

| 必要物 | 配布元 | rubygems で揃う? |
|---|---|---|
| `mrbc` バイナリ | `mruby-wasm-runtime` repo 内で build、または mruby host build | ❌ |
| `lilac-compiled.wasm` | `@takahashim/lilac-compiled` npm package | ❌ |
| `@takahashim/mruby-wasm-js` JS bridge | npm package | ❌ |

Ruby developer の素直な流れ:

```
gem install lilac-cli
lilac new my-app && cd my-app
bundle install
lilac dev      # ← 動かない (full wasm が無い)
lilac build    # ← 動かない (mrbc + compiled wasm + bridge が無い)
```

decisions §1「ビルド不要で動くこと」の精神は `lilac dev` (default `:full`) で
守られているはずだが、現状は dev も build も追加 setup を user に要求。
**single tool (`gem`) で完結する path** を提供したい。

### キーになる発見: `lilac-full.wasm` が mrbc を兼ねられる

mrbc は要するに「mruby の parser + compiler + bytecode dump」を CLI tool
として exposed しただけ。`lilac-full.wasm` には `mruby-compiler` が含まれて
いるので、これを wasmtime-rb 経由で叩けば **mrbc と等価な機能を Ruby から
直接呼べる**。`mrbc` バイナリを別途 install する必要がなくなる。

これにより 3 つの外部依存が **wasm + JS bridge の 2 つに統合** され、いずれも
1 gem に同梱可能になる。

### 提案: 単一 `lilac-wasm-bin` gem + auto-fallback

#### Part 1: `lilac-wasm-bin` gem (主提案)

新規 gem `lilac-wasm-bin` に以下を全部同梱:

```
lilac-wasm-bin/
├── data/
│   ├── lilac-full.wasm        # dev / target=full 用 (~3.9MB)
│   ├── lilac-compiled.wasm    # production target=compiled 用 (~2.7MB)
│   └── mruby-wasm-js/         # JS bridge 一式 (~50KB)
└── lib/lilac/wasm/bin.rb      # 上記 path を Ruby から expose
```

gemspec で `add_dependency "wasmtime"` を宣言。

`lilac-cli` 側の改修:

- `BytecodeBuilder.resolve_mrbc!` の discovery に **gem 経由 (lilac-full.wasm を wasmtime-rb で叩く)** path を追加。優先順位は env / config の後、外部 binary 探索より前
- `CompiledRuntimeResolver.resolve_wasm!` の discovery に gem 経由 path を追加
- `Doctor#check_compiled_runtime` に「lilac-wasm-bin gem が install されているか」のチェックを追加

#### Part 2: Auto-fallback (orthogonal、optional)

`lilac build --target compiled` が必要物を解決できない時、自動で `:full`
target に fallback + warn する mode。`lilac-wasm-bin` も `lilac-cli` 単体も
無い、かつ手元に npm setup も無い状態でも build が通る保証になる:

```
$ lilac build
Warning: lilac-compiled deps not found (mrbc / lilac-compiled.wasm).
Falling back to --target full. To build the optimized variant, run:
  bundle add lilac-wasm-bin
Built 6 page(s) ... target: full (auto-fallback)
```

opt-in flag (`--allow-target-fallback`) として実装する選択肢もあり(silent
な target 変更を嫌う運用向け)。

### 利点

3 gem 揃った時の user 体験(目指す姿):

```bash
gem install lilac-cli lilac-wasm-bin
lilac new my-app && cd my-app
bundle install
lilac dev      # ← 動く (lilac-wasm-bin の lilac-full.wasm を auto-vendor)
lilac build    # ← 動く (compiled wasm + mrbc 機能どちらも gem から)
```

npm 触らずに完結。Ruby developer の流れに馴染む。具体的な利点:

- **install 摩擦が最小**: 2 gem で全機能カバー。npm install / C toolchain 不要
- **version coherence**: full と compiled の wasm が release timing で必ず一致(npm artifact が古いまま fallback されて壊れる問題が構造的に起きえない)
- **mrbc 別 binary 不要**: `lilac-full.wasm` 内 mruby-compiler を兼用、`mrbc-bin` 系 gem を別途用意する必要がない
- **deterministic compile**: 同じ wasm → 同じ bytecode、platform 非依存
- **single mental model**: 「Lilac の wasm 関連は lilac-wasm-bin に全部入っている」で済む。doc も簡潔

### 現状の workaround

- 手動 `npm install @takahashim/lilac-compiled @takahashim/mruby-wasm-js`
- `mrbc` は手動 build(`mruby-wasm-runtime` で `make` 等、または mruby host build)
- `lilac doctor` が missing を検出して指示は出す(部分的 mitigation)

いずれも Ruby developer に npm + C toolchain 知識を要求する。

### 実装的課題

#### A. mruby-wasm-runtime 側

`lilac-full.wasm` を build-time compiler としても呼べるよう、エントリポイントを追加:

- C / mruby driver で **stdin → MRB::Compiler.compile_string → MRB::Dump.dump_irep → stdout** を実行する関数を expose(`-Wl,--export=compile_source` 等)
- `-mexec-model=reactor` は維持(browser library mode との両立)
- driver 実装は ~50 行 C もしくは小さな .rb script を mrbgem として bundle

#### B. `lilac-wasm-bin` gem の新規作成

- gem skeleton(`lilac-wasm-bin.gemspec` + `Gemfile`)
- `data/lilac-full.wasm` / `data/lilac-compiled.wasm` / `data/mruby-wasm-js/` を release ごとに同梱
- `lib/lilac/wasm/bin.rb` に path 公開定数(`LILAC_FULL_WASM` / `LILAC_COMPILED_WASM` / `BRIDGE_DIR`)
- gemspec で `add_dependency "wasmtime", "~> X.Y"`
- CI: `make lilac-full && make lilac-compiled` の output を gem に詰めて `gem push`

#### C. `lilac-cli` 側の改修

- `Lilac::CLI::WasmMrbcDriver` を新設(`require "wasmtime"` を lazy require):
  - lilac-full.wasm を `Wasmtime::Engine` で load
  - WASI stdin/stdout を pipe で繋ぐ
  - `compile_source` invoke、bytecode を回収
  - 1 build 中は engine instance を再利用して startup overhead を抑制
- `BytecodeBuilder.resolve_mrbc!` の discovery 順序に「gem 経由 (lilac-wasm-bin → WasmMrbcDriver)」を追加。優先度は config / env の後、PATH 探索より前
- `CompiledRuntimeResolver.resolve_wasm!` / `resolve_bridge!` も同じ哲学で gem 経由 path を加える
- `Doctor#check_compiled_runtime` で gem 不在を warn として表示

#### D. Auto-fallback (Part 2、別 PR 可)

- `Builder#build` 冒頭で resolver dry-resolve、不在なら target を `:full` に
  swap して warn。opt-in flag `--allow-target-fallback` で守る

### 関連する確定判断 / 既存提案

- decisions §1(Runtime canonical / CLI optional)— 本案は「optional」を install 摩擦の意味でも実現する後続整備
- decisions §18 / §18.5(`lilac build --target compiled` 単一コマンド deploy + 既定 = compiled)— default を compiled にしたので install 摩擦が build 経路で顕在化、本提案で吸収
- decisions §17(codegen canonical)— mrbc が compiled target の必須路という現状を強化、本提案で配布を整備

### ステータス

未判断。判断の論点:

- **gem name**: `lilac-wasm-bin` か `lilac-runtime` か `lilac-wasm` か。本文は `lilac-wasm-bin` で書いているが naming は要検討
- **wasmtime-rb vs wasmer-ruby**: 同等の機能だが maintenance 状況や precompiled artifact 提供状況で選ぶ。現時点では **wasmtime-rb** (Bytecode Alliance、ruby.wasm 系で実績) を推奨
- **gem サイズ**: ~6MB(wasm 2 種同梱)。Ruby gem としては大きめだが `sass-embedded` クラスの前例あり、許容範囲。dev 専用 user が compiled wasm を pull することの cost は disk のみ
- **`lilac-full` と `lilac-compiled` を分離 gem にするか統合か**: 統合 (`lilac-wasm-bin` 単一)で release coherence と install simplicity が得られる。分離する動機は薄い
- **mruby-wasm-runtime の release 同期**: lilac-wasm-bin の wasm は mruby-wasm-runtime の特定 commit からビルドされる。両者の release 同期 flow が必要

実装規模(全 part):

- mruby-wasm-runtime 側 driver: ~50 行 C + build_config 修正
- lilac-wasm-bin gem: skeleton + CI ~150 行
- lilac-cli の WasmMrbcDriver + resolver 拡張 + doctor 拡張: ~200 行
- Auto-fallback (optional): ~30 行

合計 ~430 行 + CI 整備 + mruby-wasm-runtime 側修正。3-layer 構成の前案より
大幅に縮小(`mrbc-bin` の platform 別 build CI が消えるのが大きい)。

Part 1 から着手し、release できれば Part 2 (auto-fallback) は補助機能として
後付け可能。

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


## `lilac dev` の既定を `codegen: :off` に降格

### 動機

現状 `lilac dev` は `codegen: :auto` で動いており、`.lil` を保存するたびに
`Codegen.generate` (= `Lilac::Bindings::<Class>` module の emit) が走る。
runtime には `Lilac::Directives::Scanner` が linked 済み (lilac-full target)
で、scanner が DOM walk で同じ binding を生成できるので、**dev での
codegen 経路は純粋に最適化** (mount 時の DOM walk 1 回をスキップする) に
なっている。

ADR-0017 では「codegen canonical / scanner = grammar reference」と整理
したが、dev では:

- 毎セーブの rebuild 時間に codegen + lints + cross-ref linter が乗る
  (大規模 project で数十 ms〜数百 ms)
- 生成される inline `<script type="text/ruby">` に Bindings module の
  boilerplate が混ざり、browser の dev tool で読みにくい
- codegen / scanner 二重 path のうち codegen 経路でしか出ない bug が
  dev で気付けない

prod では codegen 経路に依存している (compiled target は scanner を wasm
に linked していないため必須) が、dev は full target が既定なので、scanner
だけで十分動く。

### 提案

新設の `c.dev_codegen` 設定 (既定 `:off`) を Config に追加し、`lilac dev`
の Builder に `codegen: @config.dev_codegen` を渡す。`lilac build` 側は
`c.build_codegen` (既定 `:auto`) で独立に制御する。

```ruby
# lilac.config.rb
Lilac::CLI.configure do |c|
  c.dev_codegen   = :off      # 既定。runtime scanner で動かす
  c.build_codegen = :auto     # 既定。prod build は codegen emit
end
```

CLI フラグ:
```sh
lilac dev --codegen=auto      # 例外的に dev でも codegen を走らせたい
lilac build --codegen=off     # 例外的に prod でも scanner-only にしたい
```

### 利点

- **dev rebuild の高速化** (~10-100 ms 程度の短縮、`.lil` の規模に依存)
- **dev HTML が読みやすい** (inline script に codegen module の
  boilerplate が混ざらず、user script のみ)
- **codegen と scanner の二重 path 保守コストが dev では発生しない**
- **`:off` モードは parity-runner で日常検証されている既存の path** なので
  動作信頼性は確立済み
- ADR-0017 と整合: prod (compiled) は codegen canonical のまま、dev は
  「scanner = grammar reference」を直接利用するだけ

### 現状の workaround

`lilac.config.rb` で `c.codegen = :off` を明示すれば dev も build も
scanner 経路になる。ただし build (prod) の compiled target で `:off` に
すると wasm に scanner が無いので **動かない**。dev / build 別々に
codegen を制御できないのが現状の不便さ。

### 実装的課題

- `Lilac::CLI::Settings` (config_loader.rb) に `dev_codegen` /
  `build_codegen` を追加。既存 `codegen` は backward-compat の優先
  fallback として残す
- `Lilac::CLI::Config` で `lilac dev` の Builder 呼び出しは
  `dev_codegen`、`lilac build` は `build_codegen` を渡すよう分岐
- `lilac help` の CLI フラグ説明を更新
- docs/lilac-workflow.md に「dev での codegen 挙動」節を追加
- 既存の `codegen` 単一設定は **deprecated** とし、両方に伝播 (= 既存
  config が破壊されない移行)
- 実装規模: ~80 行 (config + builder + docs)

`.lil` を含む project では dist HTML に synthetic `data-ref="lilN"` は
引き続き injection される (template_ast の挙動は変わらない)。scanner は
synthetic ref を無視するので harmless。`refs.foo` の user-authored ref も
そのまま動く。

### トレードオフ / 懸念

- **build-time error が mount-time error に降格** — CrossRefLinter / Lints
  はそのまま走るので大半の typo は build で捕まる。値文法エラー
  (`data-text="@invalid syntax"`) のような scanner 専属のチェックだけ
  mount 時に logger.error で出る
- **codegen 経路の regression が dev で検出されにくくなる** — CI の
  `make test-cli` + parity-runner が砦になる。CI を回さない手元作業中は
  気付かない可能性
- **`--target compiled` で dev する人** (現状の `c.dev_target = :compiled`
  設定) は codegen が必要。`dev_codegen: :auto` への自動切替か、
  config validation で警告

### 関連する確定判断

- [ADR-0017](./adr/0017-codegen-canonical-scanner-grammar-only.md) — codegen
  canonical / scanner = grammar reference。本提案は「dev は scanner 経路に
  寄せる」が ADR-0017 を覆さない (prod の codegen canonical は維持)
- [ADR-0001](./adr/0001-runtime-canonical.md) — runtime canonical 原則と
  整合 (= dev で runtime path をデフォルトにすることで原則を強化)
- [ADR-0027](./adr/0027-class-first-handler-api.md) — 本提案で dev の
  scanner path が main 経路になることで、Handler API の runtime
  実装パスがより重要に

### ステータス

未判断 (proposal 段階)。**`codegen: :off` モードは Builder に既に実装済み
で parity-runner で動作検証もされている**ため、実装コストは config 周りの
~80 行のみ。dev rebuild 高速化と HTML 可読性向上が主な動機なので、
体感メリットを実測してから判断するのも一つの選択。

## `<lilac-component>` 廃止と `data-component=` / `data-use=` の役割分離

### 動機

現状の component 配置には 3 つの問題がある:

**(1) `<lilac-component>` がビルド経由でしか動かない独自 DSL**

- `lilac build` で `<lilac-component>` を `COMPONENT_PLACEHOLDER` 正規表現で
  検出し、`.lil` の `<template>` 中身に **inline 展開** する
- ランタイムは `<lilac-component>` という名前すら知らない (展開済みの
  `data-component=` を見るだけ)
- 結果、`examples/runtime-only/` のような **ノービルド** フローでは
  `<lilac-component>` が完全に無効 (`grep` で 0 件)。**`<lilac-component>`
  を使った瞬間に runtime canonical (ADR-0001) を外れる**

**(2) `data-component=` が「定義」と「利用」の両方を中立的に表す**

- `.lil` 内の `<template>` の中で書く `<div data-component="X">` は **定義** (雛形)
- ページ内に書く `<div data-component="X">` は **利用** (mount される実体)
- 同じ属性名で別の役割を担っているため、読み手にとって意図が読み取りづらい

**(3) ノービルドで「複数箇所で同じ markup を使いたい」が破綻する**

- page-inline で書いた markup を「別の場所でも再利用したい」となった瞬間、
  現状は `<lilac-component>` + `.lil` への切り出しが必要 (ビルド前提)
- ノービルド (`examples/runtime-only/`) では markup を物理的にコピペする
  しかない (= 重複)
- Alpine.js / petite-vue 等の同類ツールも同じ問題を抱えている (markup の
  再利用機構を持たない) が、Lilac はこの「ノービルドで markup を再利用
  したい」需要に応える独自ポジションを取り得る

加えて、CLI/Builder の責務肥大化 (build 機能を最小化したい中長期方針) と
合わせて、`<lilac-component>` 関連の処理 (~200 行) を builder.rb から
削れないか検討の余地がある。

### 設計哲学 — 段階的 DRY (YAGNI)

本提案の中核は **「重複が発生したときだけ抽象化する」** という DRY 原則
本来の精神 (= YAGNI と組み合わせた pragmatic DRY) に沿うことにある:

- **1 個だけ書くなら**: そのまま書く (重複していないので共通化不要)
- **2 個目を書くとき**: そこで抽象化を検討する (`data-use=` を導入)
- **Rule of Three**: 3 個目まで来たら定義箇所を `<template>` に隔離する

これは **Alpine.js / petite-vue の「inline で書く」哲学を継承しつつ、
markup 再利用が必要になったときの逃げ道を提供する**、という設計選択。
"最初から構造化を強制" (= predictive abstraction) は Lilac の軽量さと
噛み合わない、という判断。

### 提案

**`<lilac-component>` 構文を完全廃止**し、**`data-component=` と新規
`data-use=` で「定義」と「利用」を明示的に分ける**。

#### 属性のセマンティクス

| 属性 | 配置場所 | 動作 |
|---|---|---|
| `data-component="X"` | `<template>` の **中** | X の **定義のみ** (template として記録、レンダリングされない) |
| `data-component="X"` | `<template>` の **外** | **定義 + 利用** (その場で表示 + template として記録 + mount) |
| `data-use="X"` | `<template>` の **外** | **利用** (mount。要素が空なら template から markup 注入、markup あれば直書き優先) |

中心概念は「**コンポーネント (`data-component`) = 定義そのもの**」「**利用
(`data-use`) = インスタンス化**」。書き手は普段は `data-component=` だけ書けば
よく、複数の利用箇所が欲しくなったタイミングで `data-use=` を導入する。

#### 段階的な書き味

**ケース 1: 1 個だけ使う (最頻出)** — 現状の page-inline と同じ書き味:

```html
<div data-component="counter">
  <button data-on-click="decrement">-</button>
  <span data-text="@count">0</span>
  <button data-on-click="increment">+</button>
</div>

<script type="text/ruby">
  class Counter < Lilac::Component
    def setup; @count = signal(0); end
    def increment(_ev) = @count.update(&:succ)
    def decrement(_ev) = @count.update(&:pred)
  end
</script>
```

**ケース 2: 複数箇所で使う (DRY)** — 1 個目を定義 + 利用、以降は利用のみ:

```html
<div data-component="counter">
  <button data-on-click="decrement">-</button>
  <span data-text="@count">0</span>
  <button data-on-click="increment">+</button>
</div>

<div data-use="counter"></div>
<div data-use="counter"></div>
```

**ケース 3: 純粋な雛形として書く** — `<template>` に隔離、利用は全部 `data-use=`:

```html
<template>
  <div data-component="counter">
    <button data-on-click="decrement">-</button>
    <span data-text="@count">0</span>
    <button data-on-click="increment">+</button>
  </div>
</template>

<div data-use="counter"></div>
<div data-use="counter"></div>
```

**ケース 4: ネスト** — template 内に `data-use=` を書く形で自然に表現:

```html
<template>
  <div data-component="todo-list">
    <ul>
      <li data-use="todo-item"></li>
    </ul>
  </div>
</template>

<template>
  <div data-component="todo-item">
    <input type="checkbox">
    <span data-text="@text"></span>
  </div>
</template>

<div data-use="todo-list"></div>
```

template が clone されて DOM に挿入されると `data-use="todo-item"` が DOM に
出現し、既存の mount cascade で順次マウントされる。

**ケース 5: markup の上書き** — `data-use=` 要素に直書きすればそれを使う:

```html
<template>
  <div data-component="counter">...</div>
</template>

<!-- template から流し込み -->
<div data-use="counter"></div>

<!-- 個別 markup で上書き -->
<div data-use="counter">
  <h2>Custom Counter</h2>
  <button data-on-click="reset">reset</button>
</div>
```

#### 衝突はエラー

暗黙の「先勝ち」「上書き」を排除し、衝突は **エラー** とする (1 page の
scope 内で):

| ケース | 扱い |
|---|---|
| 同名 `data-component=` の重複 (どこでも) | ❌ エラー |
| `<template>` 内/外の両方に同名 `data-component=` | ❌ エラー |
| 未定義の `data-use=` (対応する `data-component=` がない) | ❌ エラー |
| `data-use=` に直書き markup | ✅ OK (直書き優先) |
| `data-use=` 多数 + `data-component=` 1 個 | ✅ OK |

エラーメッセージ例:

```
[lilac] Duplicate component definition: "counter"
  - <template>:line 5 (defines markup A)
  - <div data-component=>:line 23 (defines markup B)
  Define each component name only once per page.

[lilac] Unknown component "contre" referenced by <div data-use="contre">:line 15.
  No matching <div data-component="contre"> found.
  Did you mean "counter"?
```

#### ランタイム動作

`Lilac::Registry` (mruby-lilac) で:

1. **collect phase**: document を走査し、`data-component=` 要素を集める
   - `<template>` 内 → definition table に `{name => template}` 記録
   - `<template>` 外 → definition + mount target として記録
   - 重複検出 → エラー
2. **mount phase**: `data-component=` (template 外) と `data-use=` を走査
   - `data-use=` 要素が空 → definition table から markup を `cloneNode` で
     注入
   - markup ありの `data-use=` → そのまま使う
   - 通常通り `bind_template_hook` → mount

#### ビルド動作

`<lilac-component>` 関連処理を削除し、`.lil` の `<template>` を `<template>`
要素として `</body>` 前に inject するだけのシンプルな経路に統一:

- 削除: `COMPONENT_PLACEHOLDER` 正規表現置換、`default_markup` inline 展開、
  `synthesize_page_inline_components` 内の `<lilac-component>` 由来分岐
- 維持: `components/X.lil` がページで `data-use=` または `data-component=`
  として参照される場合、`.lil` の `<template>` を `</body>` 前に inject
  (既存の named template 注入と同じパターン)
- 衝突検出: 上記の重複/未定義チェックを build 時に先回りで実行

### 利点

- **段階的な書き味 (YAGNI/DRY 適用)** — 1 個なら `data-component=` 直書き 1
  行、2 個目で `data-use=` を足し、必要なら `<template>` に隔離する。
  最小ケースで余計な構造を強要しない。Alpine.js / petite-vue の「inline で
  書く」感覚を維持
- **Alpine 系の上位互換ポジション** — Alpine が提供できない「markup 再利用」を
  ノービルドで実現する。「Alpine の手軽さに最初は乗り、規模が育ったら
  `<template>` + `data-use=` で DRY する」という成長パスが描ける
- **「コンポーネント」という単語が直感通り** — `data-component=` が指すのは
  「コンポーネントそのもの (= 定義)」。`data-use=` は動詞で利用を明示
- **runtime canonical** — `<template>` + `data-component=` + `data-use=` は
  全部 HTML 標準タグ + `data-*` 属性。ビルド有無に関わらず同じ動作。ADR-0001
  の原則を強化
- **衝突はエラー** — 同名 `data-component=` の重複、未定義 `data-use=` を
  build / runtime 両方で検出。「先勝ち」「上書き優先」のような暗黙の
  優先順位ルールは導入しない
- **`<lilac-component>` の Web Components 風誤解を排除** — ハイフン入りタグ
  を Custom Element として実装するか否かの議論ごとなくなる
- **builder.rb の軽量化** — `COMPONENT_PLACEHOLDER` 関連 ~150〜200 行が削減。
  「build 機能の最小化」方針に整合
- **HTML 標準の `<template>` セマンティクスを活用** — 「DOM tree に出ない
  content holder」という HTML 仕様の本来の意味で `<template>` を使う

### 受容するトレードオフ

設計上「明示性を犠牲にしても段階的書き味を優先した」結果、以下 2 つの
**場所依存ルール** が残る。これは Alpine 系の `x-data` / petite-vue の
`v-scope` と同列の「軽量さのコスト」として明文化する:

**(1) `data-component=` の挙動は `<template>` 内外で変わる**

| 位置 | 挙動 |
|---|---|
| `<template>` 内 | 定義のみ |
| `<template>` 外 | 定義 + 利用 |

`<template>` 自体が「DOM tree に出ない content holder」という HTML 標準の
セマンティクスを持つため、書き手にとっては「`<template>` の中なら表示
されない = 雛形」「外なら表示される = 実体」という自然な感覚で理解できる
範囲。

**(2) `data-use=` 要素の「空判定」**

| 状態 | 挙動 |
|---|---|
| 内側が空 (whitespace/コメントのみ含む) | template から markup 注入 |
| 内側に markup あり | 直書きを優先 |

「上書き機能」のため必要。判定基準は `innerHTML.trim() === ""` をベースに、
whitespace-only / comment-only も「空扱い」とする (ユーザーの直感に
合わせる)。

これらは「暗黙ルールゼロ」ではないが、Alpine 系のような **軽量 DOM 駆動
ツールでは慣習化した形** であり、書き手の学習負荷も小さいと判断する。
「明示性最優先・暗黙ルールゼロ」を求めるなら、後述の **棄却した代替案**
を参照。

### 棄却した代替案

**案 B: `<template>` 強制 + `data-use=` markup 上書き禁止**

`data-component=` を `<template>` 内強制、`data-use=` 内の markup は常に
template で上書き (空判定を廃止) するアプローチも検討した:

```html
<!-- 案 B: 1 個だけでも <template> + data-use= が必須 -->
<template>
  <div data-component="counter">
    <button data-on-click="decrement">-</button>
    <span data-text="@count">0</span>
    <button data-on-click="increment">+</button>
  </div>
</template>
<div data-use="counter"></div>
```

- 利点: 「定義は `<template>` 内」「利用は `data-use=`」だけのルール、
  暗黙ルールゼロ、grep / コピペ / case 分析が容易
- 欠点: 1 個だけ書きたい最頻出ケースで 3 行増、上書きカスタマイズ不可、
  YAGNI に反する (重複していないものを強制構造化)

**棄却理由**: DRY 原則本来 ("重複が発生してから対処") と YAGNI に反する。
Lilac の軽量さ (`x-data` / `v-scope` 系の手軽さ) を犠牲にしてまで予防的
構造化を取る理由は薄い。明示性は失うが、`<template>` セマンティクスは
HTML 標準そのものなので書き手の認知負荷は限定的。

### 現状の workaround

不要 — 現状でも `data-component=` 直書きで書けば最小ケースは動く。ただし
複数箇所での再利用は `<lilac-component>` + `.lil` 一択となり、ノービルド
では成立しない。

### 実装的課題

**ランタイム (mruby-lilac)**:

- `Lilac::Registry` に `data-component=` / `data-use=` の collect / mount
  phase 実装 (~30 行)
- definition table の構築 (`{name => HTMLTemplateElement | Element}`)
- 衝突検出ロジック (~20 行) — 重複 / 未定義の検出と `console.error` 出力
- 空要素判定: `innerHTML.trim() === ""` ベース (whitespace/comment のみは空扱い)
- mount cascade: template clone 後に新たに出現した `data-use=` の追跡

**ビルド (CLI/Builder)**:

- `COMPONENT_PLACEHOLDER` 正規表現と関連処理を削除
- `default_markup` メソッド削除
- `synthesize_page_inline_components` から `<lilac-component>` 関連分岐を
  削除 (page-inline の `data-component=` 直書きはそのまま動作)
- `build_scope_error_message` の `:lil_vs_page_inline` / `:class_name_vs_lil`
  ケースは、新しい衝突検出 (`data-component=` の重複) に再編
- `.lil` の `<template>` を `</body>` 前に inject する経路に統一
- 衝突検出を build 時に先回りで実行 (runtime のエラーと同じロジック)
- 推定削減: ~150〜200 行 (builder.rb 938 → 750 行程度)

**互換性 (破壊的変更)**:

- `<lilac-component>` を使う全コードを書き換え:
  - `cli/lib/lilac/cli/templates/pages/index.html` (scaffold)
  - `examples/7guis/pages/*.html` (`gallery-nav` の `<lilac-component>`)
  - `examples/package-extras/pages/index.html`
  - `cli/lib/lilac/cli/templates/` (scaffold 雛形)
  - builder / doctor / command の関連テスト
- 移行戦略: 当面は `<lilac-component>` を **deprecation warning** 付きで
  受け入れ、いずれ削除するソフトランディングも可能
- ドキュメント (`lilac-spec.md`, `lilac-workflow.md`, README, examples
  README, scaffold ドキュメント等) の書き換え

**Doctor**:

- `dangling <lilac-component>` 検出ロジック (現状 `doctor.rb:94` 付近) は
  削除
- 代わりに「`data-use="X"` を使っているが対応する `data-component="X"` も
  `.lil` も無い」という未定義チェックに置き換え
- 重複 `data-component=` チェックも doctor で報告

**未解決の細部**:

- 「scope」の単位: 1 page = 1 HTML ファイル (+ ビルドで合流する `.lil` 群)
  と定義するが、SPA 的に動的に DOM が増えるケースをどう扱うか
- 動的に追加された `data-use=` の自動マウント (現状の mount cascade と
  同じ責務範囲なら問題なし)
- `data-component="X"` を `<template data-template="Y">` のような named
  slot と組み合わせた時の挙動 (既存の named template 仕様との整合)

### 関連する確定判断

- [ADR-0001](./adr/0001-runtime-canonical.md) — runtime canonical 原則。
  本提案は **canonical 原則を強化する**方向 (`<lilac-component>` という
  build-only DSL を廃止し、属性 2 種で runtime / build 両方を同一仕様に)
- [ADR-0017](./adr/0017-codegen-canonical-scanner-grammar-only.md) — codegen
  canonical / scanner = grammar reference。本提案は component 配置の話で
  直交するが、「Builder の責務縮小」という流れで方向性は一致

### ステータス

未判断 (proposal 段階)。`examples/` の grep 結果を見る限り、
`<lilac-component>` の実利用は主に「複数ページ共通 nav (gallery-nav)」と
scaffold 雛形に限られ、廃止のインパクトは限定的。

実装の規模感:
- ランタイム ~30 行追加 (collect + mount + 衝突検出)
- Builder ~150〜200 行削減
- 既存サンプル / scaffold / examples / doc の書き換え (大半は機械的置換)

「build 機能を最小化」したい中長期方針 ([ADR 未起票] CLI スリム化議論
参照) の入口として、まず本提案を実装する順序が筋良さそう。

**設計選択の確認事項** (実装着手前):

- 属性 2 種 (`data-component=` / `data-use=`) のネーミング (代替案:
  `data-template-for=` / `data-component=` 等)
- 受容するトレードオフ ((1) `<template>` 内外での挙動分岐、(2) 空判定) を
  本当に許容するか、それとも案 B (`<template>` 強制 + 上書き禁止) に振り
  直すか
- Lilac の差別化軸として「Alpine 系の上位互換 (= 段階的 DRY)」を取るのか、
  「Web Components 系の厳格分離 (= 予防的構造化)」を取るのか


