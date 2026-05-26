# 30. `.lil` の bundle delivery — `<link rel="lilac-bundle">` 戦略

決定日: 2026-05-26

## 判断

`c.delivery = :bundle` を opt-in 設定として導入し、`.lil` の `<template>` と
`<script type="text/ruby">` を **1 つの `dist/lilac.bundle.html`** に集約
する。ページ HTML には `<link rel="lilac-bundle" href="/lilac.bundle.html">`
を `<head>` に注入するだけで、各 `.lil` 由来の markup / script は page HTML
には含めない。boot helper (JS) がページロード時に bundle.html を fetch し、
`<template>` を `document.body` に append、`<script type="text/ruby">` は
DOM 再構築で再評価する。

デフォルトは互換性のため `:inline` (per-page injection、従来挙動)。`:bundle`
は config / scaffold で明示的に opt-in する形で提供する。

## 背景

ADR-0029 で `<lilac-component>` を廃止し `data-component=` / `data-use=` に
役割分離した結果、**ビルドの責務は「`.lil` を HTML に inject する」だけ**
に縮小した。しかし現状の inject 方式には次の課題が残っていた:

**(1) ページ HTML が肥大化する**

全 `.lil` の `<template>` + `<script>` が各ページの `</body>` 直前に inject
されるため、複数ページ × N コンポーネントだとページ HTML が大きくなる。
コンポーネント定義が増えるほど FCP に影響する。

**(2) キャッシュ粒度が粗い**

1 つのコンポーネント定義を更新するとページ HTML 全体が invalidate される。
**コンポーネント定義は安定するがページ markup は頻繁に変わる** プロジェクト
では、ページ毎にすべてのコンポーネント定義を再ダウンロードする無駄が出る。

**(3) ノービルドユーザーが `.lil` の DRY 機構を使えない**

ADR-0029 で「`<template>` + `data-use=` 直書きでノービルド DRY 可能」になった
が、**複数ページにまたがる DRY (= `.lil` ファイル経由)** はビルド必須。
ノービルドで「コンポーネント定義群を別ファイルに切り出して reuse」する
方法が提供されていなかった。

## rationale

### 「ビルドは集約だけ」の方針

ADR-0029 で `<lilac-component>` という build-only DSL を廃止した流れの延長
として、**ビルドの責務をさらに減らす**:

- `:inline` モード: builder がページ HTML を加工してコンポーネント定義を
  注入する (= HTML rewriting が build の仕事)
- `:bundle` モード: builder は `.lil` を 1 つの HTML に **連結する** だけ。
  ページ HTML はリンクを 1 行注入されるだけで、コンポーネント解決は runtime
  / boot helper が行う

これは ADR-0001 (runtime canonical) の原則を強化する。「delivery 形態は
runtime / boot helper が制御し、build は単純な集約だけ担当」という方向性。

### ノービルド世界観との互換

`.lil` の連結 = bundle.html は、形式が **`.lil` の集合体としてそのまま** な
ので、ノービルドユーザーも手書きできる:

```html
<!-- components.html (手書き、複数 .lil の連結) -->
<template>
  <div data-component="counter">...</div>
</template>
<script type="text/ruby">
  class Counter < Lilac::Component
    ...
  end
</script>
```

```html
<!-- index.html (ノービルド) -->
<link rel="lilac-bundle" href="/components.html">
<div data-use="counter"></div>
<script type="module">
  import { boot } from "https://takahashim.github.io/lilac/v0.1.0/index.js";
  await boot();
</script>
```

ノービルドでもページ間で markup を共有できる初の手段。Alpine.js / petite-vue
が持たない差別化ポイントを ADR-0029 から一歩進めて獲得する。

### 棄却した代替案

**案 B: manifest + N 個の `.lil` 個別 fetch**

```html
<link rel="lilac-manifest" href="/lilac.manifest.json">
```

- 利点: コンポーネント単位のキャッシュ、HTTP/2 並列ダウンロード
- 欠点: HTTP/1 でリクエスト数が増える、ビルドの責務が増える (N 個出力 +
  manifest)、ノービルドユーザーが「全コンポーネント URL リストを管理」する
  必要

**棄却理由**: 中規模アプリには過剰、HTTP/1 互換性も悪化。将来「lazy load」
ニーズが顕在化したら新規 ADR として検討する。

**案 C: 3 モード (inline / inject / bundle) 併存**

`:bundle` を加えて 3 モード保持する案。

**棄却理由**: 当面は 2 モードで十分。`:inject` (注入のみ、bundle なし) と
`:inline` の差は小さい。複雑度を下げるため `:inline` (既存) と `:bundle`
(新規) の 2 択にとどめる。

### 提案からの逸脱

提案文書 (`docs/lilac-proposals.md`) では「runtime (`Lilac::Registry#start`)
内で bundle を fetch する」と書いていたが、実装では **boot helper (JS) 側
に寄せた**:

- `Lilac::Registry` instance methods から mruby の `Kernel#eval` (mruby-eval
  gem) が呼べない。`vm.eval` は JS 側の API。
- bundle 内の `<script type="text/ruby">` を mruby ランタイムで評価するには
  どのみち JS 側で DOM 操作 + vm.eval の往復が必要

そのため bundle fetch + DOMParser + template append + script reattach の
すべてを boot helper (JS) で行い、runtime registry は **bundle が既に
appended された前提** で collect / mount を回す形になった。提案より単純で、
責務分離も明確 (JS = transport / DOM、Ruby = state / binding)。

## トレードオフ

**(1) 初回 FCP の追加 fetch ラウンドトリップ**

`lilac.bundle.html` の fetch が完了するまで `Lilac.start` が走らない。
HTTP/2 で並列化できるが、bundle が大きいと wait time が増える。緩和策:
`<link rel="preload" as="fetch">` の併用、small bundle の維持。

**(2) キャッシュ粒度はアプリ全体**

1 つの `.lil` を変更すると bundle.html 全体が invalidate される。
component 単位でキャッシュしたい場合は将来案 B (manifest) を新 ADR で
検討する。

**(3) `<script>` 自動評価のための DOM 操作**

`DOMParser` でパースした HTML 内の `<script>` は **自動評価されない** ため、
boot helper が新規 `<script>` 要素を作って append する必要がある。標準
DOM API でできるが、実装上の注意点として明記。

**(4) `:compiled × :bundle` の .mrb チェイン**

compiled wasm は parser を持たないため `vm.eval` が使えない。よって:

- `lilac.bundle.html` には `<template>` だけを書き、`<script type="text/ruby">`
  は bundle に含めない
- 全コンポーネントの script は **`bundle.mrb`** に集約コンパイル
- 各ページに **`start_only.mrb`** (`Lilac.start` だけ) も生成し、page-inline
  script がないページは `[bundle.mrb, start_only.mrb]` をチェインロード
- page-inline script があるページは `[bundle.mrb, page_local.mrb]` (後者が
  `Lilac.start` を末尾に持つ) をチェインロード

これは提案文書には書かれていなかった機微で、`:compiled` で `Lilac.start` を
どこで呼ぶかを成立させるために必要だった (decisions §20.6 caveat 由来)。

## 実装

### Phase A: ビルド側 (`cli/lib/lilac/cli/build/`)

- `Config::DELIVERY_VALUES = %i[inline bundle]` (default `:inline`) を導入
- `BundleAssetWriter` — `dist/lilac.bundle.html` を emit。`:compiled` 時は
  `bundle.mrb` + `start_only.mrb` も生成
- `PageCompiler#inject_bundle_page` — ページ `<head>` に `<link rel="lilac-bundle">`
  を注入。page-inline component や `<script type="text/ruby">` がある場合は
  page-local injection も追加
- `PageCompiler#compiled_bundle_mrb_chain` — page-local mrb の有無で 2 通り
  のチェインを生成
- `PageCompiler#render_compiled_boot_module` — `:compiled × :bundle` 用に
  bundle fetch + DOMParser + template append の JS を inline

### Phase B: Boot helper (JS)

- `examples/7guis/public/boot.js` — `<link rel="lilac-bundle">` を fetch、
  DOMParser でパース、`<template>` を `document.body` に append、
  `<script type="text/ruby">` は新規 `<script>` 要素として再作成 + append
- `pages/lilac-full/index.js` (GitHub Pages CDN 配布の boot helper) も同等
  機能を `loadLilacBundles(vm)` として実装

### Phase C: Runtime

- `Lilac::Registry#start` に明示的な記載: bundle fetch は boot helper の
  責務で、registry は append 後の DOM を前提とする

### Phase D: dev サーバ統合

- 初期実装では `DevServer#rebuild!` が `delivery: :inline` を pin していた
  が、本 ADR の delivery 戦略を dev にも適用するため pin を撤去 (commit
  `9450771`)。`lilac dev` は `config.delivery` を honor し、build と同じ
  delivery path を通す
- `LiveReload::SCRIPT` の二重注入バグを修正 (commit `f906fae`) — bundle
  mode + page-inline + live_reload で 2 つの SSE listener が発生する問題を、
  `build_injection` 側から削除して top-level entry points に責務集約

### Phase E: 例

- `examples/7guis/lilac.config.rb` に `c.delivery = :bundle` を設定
- `examples/7guis/Gemfile` に `gem "lilac-wasm-bin"` を追加 (Phase A の
  auto-vendor 連動)

### 検証

- CLI tests: 494 runs / 1200 assertions / 0 failures (regression test
  `test_live_reload_with_bundle_delivery_emits_one_script` を含む)
- `:compiled × :bundle × page-inline` の chain ロード網羅テスト 3 本追加
  (commit `ac169cd`)
- 7guis: `:full × :inline`, `:full × :bundle`, `:compiled × :inline`,
  `:compiled × :bundle` の 4 組み合わせすべてブラウザで動作確認

## 後続作業

- bundle.html 内の `<script>` 評価順序の規約明文化 (現状は記述順、複数
  script を持つ bundle は混乱の余地)
- 複数 `<link rel="lilac-bundle">` のサポート (= bundle のネスト)。実装上は
  fetch ループが順に処理するため動くはずだが、明示的なテストはない
- fetch 失敗時のフォールバック挙動の確立 (現状は `console.error` で報告し
  以降の boot を中断)
- `:bundle` をデフォルトに昇格するタイミング。`:inline` を superseded 扱いに
  するかどうかは、CDN 経路の安定とエラーハンドリングの実績次第
- 案 B (manifest + N 個 fetch) の必要性が顕在化したら新 ADR で検討

## 関連 ADR

- [ADR-0001](./0001-runtime-canonical.md) — runtime canonical 原則。本 ADR
  は **canonical 原則を強化する** 方向 (delivery 形態を runtime / boot
  helper が制御、build は単純な集約だけ担当)
- [ADR-0028](./0028-drop-npm-distribution-github-pages-cdn.md) — GitHub
  Pages CDN 配信。本 ADR の bundle.html も同じ delivery 経路に乗る (CDN
  配布の `pages/lilac-full/index.js` 内 boot helper が bundle fetch を担当)
- [ADR-0029](./0029-data-component-data-use-split.md) — `data-component=` /
  `data-use=` の役割分離。本 ADR は ADR-0029 の delivery 戦略を完成させる
  位置付け

## ステータス

完了 (Phase A〜E + 検証)。proposal 段階から実装まで一気通貫で進めたため、
本 ADR は実装後の記録として書かれている。
