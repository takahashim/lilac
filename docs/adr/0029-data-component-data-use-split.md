# 29. `<lilac-component>` 廃止と `data-component=` / `data-use=` の役割分離

決定日: 2026-05-25

## 判断

`<lilac-component name="X">` 構文を廃止し、コンポーネントの **定義** と
**利用** を `data-component=` / `data-use=` の 2 属性で表現する:

- `data-component="X"` (`<template>` 内): X の **定義のみ** (template として記録)
- `data-component="X"` (`<template>` 外): **定義 + 利用** (表示 + 定義 + mount)
- `data-use="X"` (`<template>` 外): **利用** (mount + 空なら template から markup 注入)

同名 `data-component=` の重複、未定義 `data-use=` は build / runtime 両方でエラー。

## 背景

現状の component 配置は 3 つの問題を抱えていた:

**(1) `<lilac-component>` がビルド経由でしか動かない独自 DSL**

`lilac build` の `COMPONENT_PLACEHOLDER` 正規表現で `.lil` の `<template>`
中身に inline 展開され、ランタイムは `<lilac-component>` を一切解釈しない。
結果として `examples/runtime-only/` のような **ノービルド** フローでは
`<lilac-component>` が完全に無効 (`grep` で 0 件) で、**`<lilac-component>`
を使った瞬間に runtime canonical (ADR-0001) を外れる**。

**(2) `data-component=` が「定義」と「利用」を中立的に表す**

`.lil` 内 `<template>` の `<div data-component="X">` は **定義** (雛形)、
ページ内の `<div data-component="X">` は **利用** (mount される実体)。同じ
属性名で別の役割を担うため、読み手にとって意図が読み取りづらい。

**(3) ノービルドで「複数箇所で同じ markup を使いたい」が破綻**

page-inline で書いた markup を別の場所でも再利用したい場合、現状は
`<lilac-component>` + `.lil` への切り出しが必要 (ビルド前提)。ノービルド
では markup を物理的にコピペするしかなく、Alpine.js / petite-vue と同じ
「markup 再利用機構を持たない」状態に縛られていた。

加えて Builder の責務肥大化 ([ADR 未起票] CLI スリム化議論) と合わせて、
`<lilac-component>` 関連 ~200 行を builder.rb から削れるという副次目的も
あった。

## rationale

### 核となる設計哲学: 段階的 DRY (YAGNI)

**「重複が発生したときだけ抽象化する」** という DRY 原則本来の精神 (= YAGNI
と組み合わせた pragmatic DRY) に沿う:

- 1 個だけ書くなら: そのまま書く (重複していないので共通化不要)
- 2 個目を書くとき: そこで抽象化を検討する (`data-use=` を導入)
- Rule of Three: 3 個目で定義箇所を `<template>` に隔離する

これは Alpine.js / petite-vue の「inline で書く」哲学を継承しつつ、markup
再利用が必要になったときの逃げ道を提供する、という設計選択。"最初から
構造化を強制" (= predictive abstraction) は Lilac の軽量さと噛み合わない。

### 段階的な書き味

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
    <span data-text="@text"></span>
  </div>
</template>

<div data-use="todo-list"></div>
```

### 検討した代替案

**案 B: `<template>` 強制 + `data-use=` markup 上書き禁止**

`data-component=` を `<template>` 内強制、`data-use=` 内の markup は常に
template で上書きするアプローチ。「定義と利用」を完全に分離するルール:

- 利点: 暗黙ルールゼロ、grep / コピペ / case 分析が容易、Web Components
  系の慣行に近い
- 欠点: 1 個だけ書きたい最頻出ケースで `<template>` + `data-use=` を強制、
  上書きカスタマイズ不可、YAGNI に反する

**棄却理由**: DRY 原則本来 ("重複が発生してから対処") と YAGNI に反する。
Lilac の軽量さ (Alpine.js 系の手軽さ) を犠牲にしてまで予防的構造化を
取る理由は薄い。明示性は失うが、`<template>` セマンティクスは HTML 標準
そのものなので書き手の認知負荷は限定的。

### `<lilac-component>` を Custom Element として再定義する案も棄却

「Web Components 経由で `<lilac-component>` を runtime canonical 化する」
案も検討したが、Shadow DOM / Element lifecycle / ElementInternals 等の
Web Components の本格機能を使わない最小実装は **「中途半端な Custom
Element」と Web 開発者に映る** リスクが大きく、また属性ベースの表現
(`data-component=` / `data-use=`) で同じ目的が達成できるため、独自タグの
導入は不要と判断した。

## トレードオフ

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

### 衝突 = エラー

暗黙の「先勝ち」「上書き」「優先順位」は導入しない:

| ケース | 扱い |
|---|---|
| 同名 `data-component=` の重複 (どこでも) | ❌ エラー |
| `<template>` 内/外の両方に同名 `data-component=` | ❌ エラー |
| 未定義の `data-use=` | ❌ エラー |
| `data-use=` 多数 + `data-component=` 1 個 | ✅ OK |
| `data-use=` に直書き markup | ✅ OK (直書き優先) |

エラーは build / runtime 両方で検出。ノービルドでも `console.error` で
報告されるので、CLI を介さない使い方でも気づける。

### 差別化ポジション

新設計は Lilac を **「Alpine.js の上位互換」** に位置付ける:

- Alpine.js / petite-vue: ノービルド、inline 派、**markup 再利用は提供しない**
- Lilac (新仕様): ノービルド、inline 派、**markup 再利用を提供** (`<template>` +
  `data-use=`)
- Web Components / Stimulus: 厳格分離、ビルド前提が標準

「Alpine の手軽さに最初は乗り、規模が育ったら `<template>` + `data-use=`
で DRY する」という成長パスを描ける独自ポジションを獲得する。

## 実装

### Phase 1: ランタイム拡張 (mruby-lilac)

- `Lilac::Registry#start` に collect_definitions + expand_uses フェーズを追加
- `collect_definitions`: `<template>` 内/外の `data-component=` を集めて
  `{name => element}` の table を作成、重複は `console.error`
- `expand_uses`: `data-use=` 要素に template から markup 注入 (空判定あり)、
  未定義は `console.error`
- `collect_components` / `instantiate_component` を拡張し `data-use=` も
  mount 対象として扱う

### Phase 2: ビルド側修正 (cli/lib/lilac/cli/build/builder.rb)

- `COMPONENT_PLACEHOLDER` 正規表現を `DATA_USE_PATTERN` に置き換え
- `default_markup` メソッドを削除
- `render_default_template` メソッドを追加 (`.lil` の default markup を
  `<template>` 要素として包んで `</body>` 前に inject)
- `build_injection` を拡張し `default_templates` を `parts` に含める
- `doctor.rb` の dangling-component 検出を `data-use=` 検出に変更

### Phase 3: テスト修正

- `cli/test/*.rb` の `<lilac-component>` 使用箇所を `data-use=` に書き換え
- エラーメッセージ regexp を新形式に更新

### Phase 4: scaffold / examples / docs 書き換え

- `cli/lib/lilac/cli/templates/pages/index.html` (scaffold)
- `examples/7guis/pages/*.html`
- `examples/package-extras/pages/index.html`
- `test/parity-fixtures/*/pages/index.html`
- `README.md`, `cli/README.md`, `docs/lilac-workflow.md`

### 検証

- CLI tests: 487 runs, 0 failures, 0 errors (4 skips は環境的)
- wasm_spec (Ruby host): 71/71 spec files pass
- wasm_spec (Node + happy-dom): 全 pass
- 7guis ビルド: 成功 (data-use= が残り、`<template>` 定義が注入される)

## 後続作業

- `build_scope_error_message` の `:lil_vs_page_inline` ケースを新仕様の
  命名 (「同名 component 定義の重複」) に整理
- build 時の `<template>` スキャンを拡張し、ページ HTML 内の `<template>`
  内 `data-component=` も収集対象にする (現状はノービルド runtime のみが
  対応)
- 関連 spec doc (lilac-spec.md, lilac-directive-spec.md) への反映

## 関連 ADR

- [ADR-0001](./0001-runtime-canonical.md) — runtime canonical 原則。本 ADR
  は **canonical 原則を強化する** 方向 (`<lilac-component>` という
  build-only DSL を廃止し、属性 2 種で runtime / build 両方を同一仕様に)
- [ADR-0017](./0017-codegen-canonical-scanner-grammar-only.md) — codegen
  canonical / scanner = grammar reference。本 ADR は component 配置の話で
  直交するが、「Builder の責務縮小」という流れで方向性は一致

## ステータス

完了 (Phase 1〜4 + parity-fixtures 更新済み)。
