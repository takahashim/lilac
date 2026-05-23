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

## Directive plug-in 機構: 名前ベース命名規約

### 動機

Step 2 で form を `mruby-lilac-directives` から `mruby-lilac-form` に分離し、
Scanner / Codegen / TemplateAST に拡張点 API
(`register_directive` / `register_emitter` / 各種 hook)
を入れた。これで「第三者が独自 directive を作れる」状態にはなったが、
実際に `mruby-lilac-extras` で `data-tooltip` / `data-autofocus` を試作
してみると以下の摩擦が顕在化した:

1. **plugin 作成に 2 ファイル必要**: `runtime/mruby-lilac-X/mrblib/*.rb`
   (runtime registration、mruby)+ `cli/lib/lilac/cli/X_extension.rb`
   (CLI emitter、MRI Ruby)。物理的に別ツリー、別 VM
2. **同じ概念を 2 回書く**: tooltip が「`title` 属性に bind」という事実を
   runtime side で `host.bind(ref, attr: {...})`、CLI side で
   `"bind ... attr: {...}"` 文字列、それぞれ別表現で書く
3. **block ベース registration は CLI が読み取れない**: runtime の dispatch
   block は mruby で走るので CLI からは「中身を知らない blob」になる。
   CLI emit は手書きするしかない

### 既存ポリシー (§17) との関係 — 問題提起

§17 で **directive grammar の SSOT 構造** が確立されている:

- `Value` / `Grammar` / `ClassParser` / `Compat` 等の **core directive grammar**
  は CLI と runtime に **diff-0 ペア** で並ぶ (`diff(1)` が 0 を返す状態)
- 編集時は両方を同時更新、片側だけの修正は spec 違反
- binding 経路は **codegen が canonical** (scanner gem は grammar reference +
  `codegen :off` の escape hatch)

問題は **§17 が core directive を対象としていて、extension directive (plug-in)
についての policy が未定義** なこと。Step 2 で plug-in 機構を入れた時、
extension directive を `mruby-lilac-extras` のような第三者 gem で書こうとすると、
§17 の diff-0 ペア方式をそのまま当てはめると **plugin 作者にも CLI/runtime 両側に
同じコードを書かせる** ことになる。これは plug-in 機構として摩擦が大きい。

本提案は **§17 を補完する形で extension directive 用の policy を確立する**:

| | Core directive (§17) | **Extension directive (本提案)** |
|---|---|---|
| Grammar layer (`Value` / `Grammar` 等) | CLI/runtime **diff-0 ペア** | (使用するだけ、編集対象外) |
| Dispatch logic | CLI emitter (`emit_X`) + runtime dispatch、別実装 | **mrblib 単一 SSOT、CLI は AST 参照のみ** |
| binding 経路 | codegen が canonical | codegen が canonical (CLI が emit する内容は **extension method call**) |
| 同期コスト | 同じコードを 2 言語実装で並べる | 1 ファイルのみ、CLI が自動配線 |

binding 経路が **codegen canonical のまま** であることに注意 — §17 を覆さない。
CLI codegen は extension directive を見つけたら
`Lilac::Extras.hook_tooltip(...)` という **メソッド呼び出しコード** を emit
する。Plugin の dispatch 実装は mruby と MRI の両方から呼ばれる「単一 method
として SSOT」 (runtime: 実 Scanner が呼ぶ、CLI: codegen 出力が呼ぶ)。両者が同じ
method を呼ぶことで挙動 divergence が原理的に防がれる
(§6 / §22 の "runtime と CLI で振る舞い一貫" 原則を保持)。

### 提案

`register_directive` (block ベース、低レベル) に加え、
**命名規約ベースの高レベル API `register_named_directive` を新設**:

```ruby
# runtime/mruby-lilac-extras/mrblib/lilac_extras.rb
module Lilac
  module Extras
    Lilac::Directives::Scanner.register_named_directive("tooltip")
    Lilac::Directives::Scanner.register_named_directive("autofocus")

    def self.hook_tooltip(scanner, raw_value, el, item)
      value = Lilac::Directives::Value.parse(raw_value)
      return if item.nil? && value.bare_ident?
      source = scanner.evaluator.bind_source(value, item)
      scanner.host.bind(scanner.wrap_ref(el), attr: { "title" => source })
    end

    def self.hook_autofocus(_scanner, _raw, el, _item)
      el.call(:focus)
    end
  end
end
```

**規約:**

- `register_named_directive("foo-bar")` は `data-foo-bar` 属性を扱う
  directive として登録される
- dispatch 時、**呼び出し元 module の `hook_foo_bar` メソッド** が
  自動的に handler になる(kebab-case → snake_case 変換)
- メソッドシグネチャは `(scanner, raw_value, el, item)` で固定
- registration には **validation metadata** を kwargs で渡せる
  (build-time check を runtime と整合させるため。詳細は論点 (k))

```ruby
Lilac::Directives::Scanner.register_named_directive(
  "tooltip",
  value: :reactive,        # Value.parse 必須 (= data-text と同じ)
)
Lilac::Directives::Scanner.register_named_directive(
  "autofocus",
  value: :none,            # 値を取らない
  allowed_tags: %w[input textarea select button],
)
```

#### CLI 側の仕組み

CLI は build 時に **`runtime/mruby-lilac-*/mrblib/**/*.rb` を Prism スキャン**
して以下を抽出:

1. `register_named_directive("X")` の呼び出し位置
2. その呼び出しを囲む `module ... end` の constant path

これで `{"tooltip" => "Lilac::Extras", "autofocus" => "Lilac::Extras"}`
のテーブルが build 起動時に得られる。codegen 時に未知 directive を見ると
このテーブルを引いて以下を emit:

```ruby
# 生成される bind_template_hook (抜粋)
Lilac::Extras.hook_tooltip(__scanner_proxy_for(refs.lil0), "@msg", refs.lil0.to_js, nil)
```

CLI 側は **AST マッチャー不要**。`register_named_directive` の呼び出し
位置だけ拾えば良い(call node の receiver + 第 1 引数 + 親 module 名)。

### 利点

1. **plugin 作成は mrblib 1 ファイルで完結**
   (`cli/lib/lilac/cli/X_extension.rb` を書かなくて良い)
2. **AST マッチャー実装不要**: CLI は call site を 1 種類認識するだけで、
   block 本体の AST 形状を解釈する必要がない
3. **CLI / runtime とも同じメソッドを呼ぶ**: 挙動の二重実装が消える。
   build-compiled と runtime mount の振る舞いが定義から一致する
4. **デバッグ容易**: スタックトレースが `Lilac::Extras.hook_tooltip` を
   直接指す。block 内の匿名 proc より遥かに追いやすい
5. **テスト容易**: メソッドを直接呼べる。Scanner mock を作るだけで
   unit test 可能
6. **読みやすい規約**: 「`data-X` の実装は `hook_X` メソッド」というルールは
   新参の plugin author にとっても把握しやすい

### 失うもの

- **inline block で closure 状態を畳み込む書き方ができない**: メソッド
  ベースになるので、複数 directive で共有したい状態は module 定数 /
  class variable で表現する必要がある。directive plugin は通常 stateless
  なのでほぼ影響なし
- **匿名 directive (一時的な実験)**: 試作で名前を付けずに register したい
  ようなケースは block 版を使う必要がある
- **同じメソッド本体を異なる名前に何度も登録**: エイリアスを書く必要が
  ある(レアケース)

これらは ` register_directive` (block 版) を低レベル API として残しておけば
カバー可能。

### 現状の workaround

現状の Step 2 完了状態でも plugin は作れる。ただし:
- mrblib + cli/lib の 2 ファイル
- block dispatch と CLI emitter の 2 経路に同じ概念を書く
- CLI emitter は private method 呼び出しになる箇所が出てくる
  (e.g., `codegen.__send__(:emit_field, ...)`)

これで動くが、plugin 作成のオンボーディング体験は悪い。提案を入れると
このコストが激減する。

### 設計上の論点

#### (a) Extension が独自 grammar を持てるか

Extension directive (`data-tooltip="@msg"`) の値が `@ivar` / bare ident のみ
という制約は core 由来 (`Lilac::Directives::Value.parse`)。Extension が新しい
grammar (例: `data-shortcut="ctrl+s"` のキー組合せ式) を持ち込みたい場合は?

選択肢:

1. **Extension は core grammar (`Value`) しか使えない** — シンプル、制約強い。
   `Value.parse` が nil を返す入力は plugin 側で raw_value を直接処理する
   (= 値の意味解釈は plugin が自分でやる)
2. **Extension が独自 parser を持てる** — 自由度高い、grammar の SSOT が
   崩れる(plugin ごとに別 grammar 規約が増える)

第一版は **(1)**: core `Value` を使うか、それで足りない場合は plugin が
`raw_value: String` をそのまま消費する。§17 の grammar SSOT は core に限定
保持。

#### (b) CLI が読みに行く mrblib の範囲

CLI が `runtime/mruby-lilac-*/mrblib/**/*.rb` を Prism スキャンする対象は:

1. **全部** (sibling discovery — `runtime/` 配下の全 gem を見る)
2. **build_config に列挙された gem のみ** (lilac-full.rb / lilac-compiled.rb
   の `conf.gem` 行に対応する gem だけ)

(2) が安全。理由: lilac-full に含まれない gem の directive を CLI が emit
すると、runtime にはロードされていないので `NoMethodError` が起きる。
build_config と CLI の認識を一致させる必要。

実装的には `MRuby::CrossBuild` の config を MRI で parse するか、もしくは
**build_config パスを CLI 起動時に渡す** (env var or argument) のが現実的。

#### (c) `lilac-compiled` variant での挙動

`lilac-compiled` は `mruby-compiler` を含まないが `mruby-lilac-directives`
gem は含まれる (= Scanner クラスはある)。Extension directive を
`lilac-compiled` で使う場合:

- CLI codegen で `Lilac::Extras.hook_tooltip(...)` を emit
- runtime には `Lilac::Extras.hook_tooltip` メソッドが存在 (extension gem
  が `lilac-compiled.rb` build_config に含まれていれば)
- → 動く

問題: extension gem が `lilac-compiled.rb` に含まれていないと
`NoMethodError`。これは:

- (i) **CLI build 時にチェックして error** ("plugin `mruby-lilac-extras`
  is not in lilac-compiled build_config — add it or remove `data-tooltip`
  from templates")
- (ii) **plugin gem が両 variant に含まれることを慣行** とする
  (build_config 側の問題、CLI はチェックしない)

(i) の方がユーザフレンドリ。第一版で実装するかは別問題、最低限 doc に
trade-off を書いておく。

#### (d) handler module の決め方

検討した 3 通り:

1. ~~呼び出し元 module を `self` で自動取得~~
   — Phase 0 検証 (P0-1) で **採用不可** と判明。`Module.nesting` は
   メソッド定義位置の lexical scope を返すので、`register_named_directive`
   内から呼び出し元 module を捕捉できない(これは mruby/MRI 共通の仕様)
2. **明示指定 (`handler: self` kwarg)**:
   `register_named_directive("tooltip", handler: self, value: :reactive)`
   — `module Lilac::Extras` 内で書けば `self` は `Lilac::Extras` を指す
3. メソッド参照を渡す:
   `register_named_directive("tooltip", &method(:hook_tooltip))`
   — メソッド定義が register より前である必要があり順序依存

**採用: (2) `handler: self` kwarg 明示渡し**。Plugin author は
`handler: self` を書く必要があるが、kwarg なので他の metadata
(value:/allowed_tags: 等) と一貫した shape になる。

CLI 側は AST nesting (`module ... ; register_named_directive(...) ; end`
の入れ子) からも resolve できるので、`handler:` 省略時のフォールバック
としても使える(が、registration の意味を一意にするため第一版では明示
を必須にする)。

#### (e) captures_name (例: `data-on-X`) の扱い

`data-on-click` のように X 部分をキャプチャする directive は第三者 plugin
で必要になるか? Lilac の built-in (`data-on-X` / `data-attr-X` / `data-css-X`)
を見ると captures_name は frameworkly 機能で、plugin がこれを作るのは
レアケース。

**第一版ではサポートしない** (= captures_name 系は block 版 `register_directive`
で書く)。需要が出てきたら `register_named_directive("on-")` のように
trailing dash で示す等の構文を追加。

#### (f) シグネチャ

```ruby
def self.hook_X(scanner, raw_value, el, item)
```

の 4 引数固定。`name`(captures_name 用)と `descriptor`(エラーメッセージ用)
は当面省略。これらが要る directive は block 版で書く。

#### (g) `register_directive` (block 版) との共存

両 API は **異なる経路で動く** ものとして残す:

- `register_directive` (block 版): 低レベル、自由、**CLI は関知しない**
  (= runtime scanner が dispatch する `lilac-full` のみで動作)
- `register_named_directive` (convention 版): 高レベル、規約に縛られる、
  **CLI が自動配線** (`lilac-full` / `lilac-compiled` 両 variant で動作)

built-in (`mruby-lilac-form`) は **当面 block 版のまま**で良い。Step 2 の
Form 分離で block 版に統一しており、現状動いている。Migrate するかは
別議論。**Block 版が将来非対応になっても容認**(pre-1.0、形を整える時期)。

#### (h) runtime fallthrough は実装しない

block 版 directive 用に runtime fallthrough
(generated `bind_template_hook` の末尾で Scanner が extension directives を
拾う仕組み)を CLI 側に組み込むかどうか:

**実装しない**。理由:

- Block 版 plugin は `lilac-full` でのみ動作する制約を許容する
  (= block 版 directive が含まれる component を `lilac-compiled` で
  build しようとすると、CLI は当該 directive を不明として `Codegen::Error`
  で build を止める)
- これにより plugin author に対するメッセージが明確: 「`lilac-compiled`
  に乗せたければ `register_named_directive` を使う」
- Runtime fallthrough という二重経路を避けることで実装複雑度を抑える

#### (i) Directive name の衝突 / 重複登録

複数 plugin が同じ name で `register_named_directive` を呼ぶ、または built-in
と同名の name で呼ぶ場合の挙動。

**方針: register 時に raise**:

- 2 つの extension gem が `register_named_directive("tooltip")` を呼ぶと
  2 回目の register が `Lilac::Error: directive :tooltip is already registered`
- Built-in (`text` / `bind` / `each` / `key` / `class` / `component` /
  `on` / `attr` / `css` / `show` / `hide` / `unsafe-html` / `form` /
  `field` / `button`) と同名で register すると raise (= 予約名扱い)
- 同一 plugin 内で 2 度 register したらやはり raise

理由: 「誰の `data-X` が動いているか」が曖昧な状態が ecosystem の
debugging を破壊する。最初の使用者が勝つルールを明確化する。

CLI 側もこの check を build 起動時の mrblib スキャンで行う(scan 順序で
最初に見つかった register が "占有"、後続 register があったら raise)。

#### (j) Iteration (`data-each`) スコープでの挙動

Extension directive が `data-each` の中で使われたときの semantics:

```html
<li data-each="@items" data-key="id"
    data-tooltip="name">         <!-- bare ident: item.name -->
  ...
</li>
```

**方針: built-in (`data-text` 等) と同じ規約に従う**:

- `@ivar` value → 通常通り `scanner.evaluator.bind_source(value, item)`
  で signal/computed を取り、bind
- bare ident value → iteration item の field 参照。
  `item.nil? && value.bare_ident?` の場合は silent skip
  (= 「iteration 外で bare ident → 何もしない」が core 規約)

Plugin author は `data-text` / `data-attr-X` 等と同じ semantics を期待
できる。Iteration スコープごとの per-row 再 dispatch も built-in と同じ
タイミングで起きる(Scanner の `scan_subtree(row_node, item: it)` 経由)。

これは plugin author が明示的に書くものではなく、`scanner.evaluator.bind_source`
を使う限り自動的に保たれる規約。

#### (k) Build-time validation: CLI と runtime の severity 整合

Built-in directive は CLI が build 時に validation を行う(値の文法、
タグ妥当性、衝突等)。Extension directive で同じ整合を保つには:

**方針: registration metadata で declarative に validation を表現、
CLI/runtime 両側が同じ metadata を消費**:

```ruby
Lilac::Directives::Scanner.register_named_directive(
  "tooltip",
  value: :reactive,           # :reactive | :ident | :none | :class_hash | :custom
  allowed_tags: nil,           # nil = any tag OK / Array = 限定
  conflicts_with: [],          # 共存不可な他 directive kind の Symbol list
  iteration: :both,            # :both (default) | :item_only | :host_only
)
```

**Schema の意味**:

| キー | 値 | 検証内容 |
|---|---|---|
| `value:` | `:reactive` | `Value.parse(raw)` が nil → build error |
| | `:ident` | `Grammar.method_ident?(raw)` が false → build error |
| | `:none` | raw が非空 → build error (値を取らない) |
| | `:class_hash` | `ClassParser.parse(raw)` が raise → build error |
| | `:custom` | plugin が `validate_<name>(raw_value)` を提供、CLI/runtime とも呼ぶ |
| `allowed_tags:` | Array of tag names | `directive.element_tag` が含まれない → build error |
| `conflicts_with:` | Array of kind symbols | 同要素に対象 directive あり → build error |
| `iteration:` | `:item_only` | iteration 外で使用 → build error |
| | `:host_only` | iteration 内で使用 → build error |

CLI は **AST で kwargs を読むだけ**で検証ロジックを再利用。Runtime は
同じ metadata から同じ validation を実行。**両側のコードが原理的に
divergence しない**(metadata SSOT)。

**Custom validation の escape hatch**:

Schema に収まらない directive は `value: :custom` + plugin が
`validate_<name>(raw_value)` クラスメソッドを提供:

```ruby
module Lilac::Extras
  Lilac::Directives::Scanner.register_named_directive(
    "shortcut", value: :custom
  )

  def self.validate_shortcut(raw_value)
    unless raw_value.match?(/\A(ctrl|alt|shift|meta)\+/i)
      raise Lilac::Error, "data-shortcut: expected key combo (got #{raw_value.inspect})"
    end
  end

  def self.hook_shortcut(scanner, raw_value, el, item)
    # ...
  end
end
```

CLI は MRI 側で `Lilac::Extras.validate_shortcut(raw_value)` を呼ぶ(plugin の
mrblib が MRI でも load 可能であることが前提 — 実装的課題セクションで議論)。

これにより **§6 / §22 (runtime と CLI の severity 整合) が plug-in 領域でも
保たれる**。

#### (l) Plugin gem の load order と discovery

CLI が `runtime/mruby-lilac-*/mrblib/**/*.rb` をスキャンする時の順序:

**方針: alphabetical 順、衝突は raise**:

- Plugin gem のディレクトリ名 (`mruby-lilac-X`) で alphabetical 順
- 同一 gem 内の mrblib ファイルも alphabetical 順 (mrubygem の慣行と一致)
- 順序依存しない設計を推奨するが、念のため最初に register したものが勝つ
  (後続は (i) のルールで raise)

Build_config (`lilac-full.rb` / `lilac-compiled.rb`) に列挙されている
gem のみをスキャン対象とする (= 論点 (b) で決定済み)。
Build_config 外の gem は CLI からも runtime からも認識されない。

### 実装的課題

#### Runtime 側

- `Scanner.register_named_directive(name, value: :reactive, allowed_tags:
  nil, conflicts_with: [], iteration: :both, handler: nil)` を追加
  (~80 行):
  - kebab-case `name` → snake_case メソッド名 (`hook_<name>`)
  - handler 省略時は **`Module.nesting` 相当で呼び出し元 module を捕捉**
    (mruby での実装可能性は要 PoC、不可なら明示渡し方式 (論点 (d) の (2)) に切替)
  - Name 衝突は登録時に raise (built-in 名 + 既登録 name 両方を check)
  - Metadata は EXTENSIONS[:directives][kind] に保存
- `Scanner#dispatch` で extension method を呼ぶ前に **metadata 由来の
  validation を実行** (CLI と同じ check が runtime でも走る)
- `register_directive` (block 版) は変更なし、CLI からは認識されないだけ

#### CLI 側

- 起動時 (`builder.rb` の require 直後) に build_config (`lilac-full.rb`
  等) を parse して plugin gem 一覧を取得
  - `MRuby::CrossBuild` の monkey patch / regex 抽出など。詳細は別検討
- 列挙された gem の `runtime/mruby-lilac-*/mrblib/**/*.rb` を **alphabetical 順**
  に Prism スキャン
- `register_named_directive("X", ...)` の call node を抽出:
  - 第 1 引数 → directive name
  - kwargs → validation metadata schema
  - 親 `module ... end` の constant_path → handler module
  - 結果は `{ "tooltip" => { handler: "Lilac::Extras", value: :reactive, ... } }`
- 衝突は scan 時に raise (= 論点 (i) の build-time 検出)
- `TemplateAST.register_directive` と `Codegen.register_emitter` を auto-call
- Emit 前に metadata の validation を実行 (value/allowed_tags/conflicts/iteration
  の 4 種、`value: :custom` の場合は `Lilac::<Module>.validate_<name>(raw_value)`
  を MRI 側で呼ぶ)
- スキャンは build 起動時 1 回。`runtime/` の更新があれば再起動が必要だが
  通常開発フローで問題なし

#### gemspec / packaging

- `lilac-cli.gemspec` の `spec.files` に `runtime/mruby-lilac-*/mrblib/**/*.rb`
  を含めるかは別議論(現状 `lib/` 配下しか含まない)
- Gem install 経由の利用パス (`runtime/` が sibling に無い場合) は将来検討
- 当面は monorepo 前提で「`runtime/` と `cli/` が sibling にある」開発
  layout を維持

#### Validation の共通実装

`value: :reactive` 等の標準検証ロジックは **diff-0 ペア構造で
CLI/runtime 共用**:

```
cli/lib/lilac/directives/validation.rb          diff-0
runtime/mruby-lilac-directives/mrblib/
  lilac_directives_validation.rb                diff-0
```

Schema 各キーに対応する predicate (`Validation.check_value!(raw, mode)`
等) を実装し、両側で同じコードを走らせる。これは §17 の grammar SSOT
と整合する追加。

#### 既存 extras gem の migrate

PoC として作った `mruby-lilac-extras` を新 API で書き直す:
- `register_directive(...) { ... }` → `register_named_directive(...) +
  def self.hook_X`
- `cli/lib/lilac/cli/extras_extension.rb` 削除
- `cli/lib/lilac/cli/builder.rb` の `require_relative 'extras_extension'` 削除

### 関連する確定判断

- **§1 (Runtime canonical 化)**: 「runtime が canonical、CLI は optional
  optimization layer」の原則を **extension directive にも明示的に適用**。
  Plugin author は CLI のことを考えなくて済む = §1 の精神を強化
- **§17 (directive binding は codegen が canonical / scanner gem は grammar
  reference + diff-0 SSOT)**: 本提案は **§17 を覆さない / 補完する**。
    - binding canonical は codegen のまま (CLI が `Lilac::Extras.hook_X(...)`
      を emit する責務を持つ)
    - Core grammar の diff-0 SSOT (Value/Grammar/ClassParser/compat_rules)
      は維持。Extension はこの grammar を使う側
    - Extension dispatch logic は §17 の SSOT 構造から **明示的に除外** し、
      mrblib 単一 SSOT とする (= 新ポリシー)。理由: plug-in 機構として
      diff-0 ペアを要求すると plugin 作者の負担が大きすぎる
- **§6 / §22 (runtime と CLI の振る舞い一貫)**: 本提案では runtime / CLI
  両方が **同じメソッド** (`Lilac::Extras.hook_X`) を呼ぶことで一貫性が
  原理的に保たれる
- **§22.6 (form 分離の後続作業)**: §22.6 は「runtime FormWiring の
  plug-in 化」「CLI template_ast / codegen の plug-in 化」を後続として
  挙げており、これは Step 2 で実装済み。本提案はその **更に次の段階**
  ( plug-in 機構の利用しやすさを向上 ) として位置付く

### 本提案が確定した場合の §17 更新

採用が決まったら decisions.md §17 にも以下を反映する:

- §17.B.scanner gem の役割整理 に
  「**Extension directive の registry を保持** (`EXTENSIONS` Hash)」
  を追加
- §17.B の SSOT 構造に以下を追記:
  - 「**Extension directive の dispatch logic は core ではなく mrblib 単一 SSOT**」
  - 「Extension の validation metadata は registration site が SSOT、
    CLI/runtime とも同じ metadata を消費」
- §17 の diff-0 ペアルールの適用範囲を「core grammar + validation
  predicate」と明示 (validation.rb を追加)

### ステータス

**未判断 / 提案段階**。Step 2 完了 + E0-E2 (mruby-lilac-extras PoC) 完了
時点での observation を元にした提案。

論点 (i)〜(l) は **方針確定済み** (本 update 時点):

- (i) name 衝突 → register 時 raise
- (j) iteration scope → built-in と同じ規約
- (k) build-time validation → metadata schema (案 B) 採用
- (l) load order → alphabetical、衝突は raise
- (g)(h) → block 版は CLI 非対応、`lilac-full` のみで動作する制約を受容
  (= 非互換 OK)

Phase 0 (PoC 検証) は **完了 (2026-05-23)**。検証結果:

1. **`Module.nesting`**: ❌ 呼び出し元 lexical scope は取れない (mruby/MRI 共通)
   → 論点 (d) を **`handler: self` kwarg 明示渡し** に確定
2. **Prism mrblib スキャンコスト**: ✅ 17 ファイル / 10ms (cold) / 8ms (warm)
   推測の 1/10、100 plugin スケールでも許容範囲
3. **Plugin mrblib の MRI load**: ✅ minimal stubs で load 可能、`validate_X`
   呼び出しは問題なく動作
4. **build_config からの gem 抽出**: ✅ 正規表現抽出方式で十分
   (`conf.gem "...path/mruby-lilac-X"` パターンを grep、core gem を除外リスト
   で弾く)

残る論点 (= 第一版で詰めなくて良いが proposal に列挙だけしておく):

- captures_name 系 (`data-on-X`) のサポート (現状 block 版で書く)
- Plugin 作者向け testing strategy / mock utility 提供
- Plugin spec doc の構造 (`docs/lilac-directive-plugin-spec.md` 新設?)
- Hot-reload / dev server との interaction
- `lilac-compiled` で plugin gem が build_config 不在の場合の検出


