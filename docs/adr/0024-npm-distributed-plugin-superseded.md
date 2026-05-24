# 24. Plug-in 配布形態: `lilac-compiled` core + 個別 npm plug-in パッケージ (superseded by §25)

決定日: 2026-05-23 (superseded 同日)

本節の方針 (npm 経由の plug-in 配布) は §25 で覆された。理由 / 経緯は
§25 で詳述。実装は §24 のものを一度全部入れた後で §25 にリセットした
形になっている (本 doc 内に sunk cost の記録として両節を残す)。

## 24.0 §25 による上書き要点

- plug-in は **rubygems 配布**に統一 (`lilac-plugin-extras` 等の gem)
- `lilac-compiled` wasm は **npm 配布しない** (`lilac-wasm-bin` gem 経由のみ)
- npm に残るのは `@takahashim/lilac-full` 1 つ、用途は CDN 経由 (`esm.sh`
  / `jsdelivr` 等) の「お試し」入り口に限定
- 詳細は §25 を参照

以下の §24.1 〜 §24.7 は元判断のスナップショット (覆された後も history
として残す)。



## 24.1 判断

§23 の plug-in 機構 (runtime fallthrough) を **配布形態の分割**まで貫徹する。
公式が複数の "compiled variant" を組み合わせ別に配るのではなく、**core 1
variant + 個別 plug-in npm package** という形で配布する。

- **core wasm variant は 1〜2 種類に絞る**:
  - `@takahashim/lilac-full` — mruby-compiler 込み、router/async/extras
    も linked (現状維持)
  - `@takahashim/lilac-compiled` — compiler なし、`vm.loadBytecode` 駆動。
    `mruby-lilac` / `mruby-lilac-directives` / `mruby-lilac-form` のみ同梱
    (form は §2 で core 確定)
  - 必要に応じて将来 `lilac-compiled-minimal` (form 抜き) を検討するが
    **当面は 1 つの compiled variant に集中**
- **Plug-in は個別 npm package**:
  - `@takahashim/lilac-plugin-extras` — `data-tooltip` / `data-autofocus`
    (directive plug-in。`register_directive` で Scanner に登録)
  - `@takahashim/lilac-plugin-router` — `Lilac::Router` (class plug-in。
    pre-load で class を提供)
  - `@takahashim/lilac-plugin-async` — `Fetchy` / `Lilac::Resource` /
    selector helpers (class plug-in)
  - 各 package は **pre-compiled `.mrb` bytecode** を同梱
- **ユーザの使い方**:
  ```js
  import { boot } from "@takahashim/lilac-compiled";
  import { loadExtras } from "@takahashim/lilac-plugin-extras";

  const extrasMrb = await loadExtras();
  await boot({ bytecode: appMrb, plugins: [extrasMrb] });
  ```
  `boot()` が `plugins` を **`appMrb` より先に** `vm.loadBytecode` する
- **Plug-in 作者向け build path**: 既存の `mrbc-host.wasm` +
  `WasmMrbcDriver` を再利用。`lilac plugin-build my_plugin.rb -o my_plugin.mrb`
  という subcommand を新設し、`.lil` build pipeline と同じ wasm-driven mrbc
  経路で `.mrb` を生成

## 24.2 背景

§23 で「公式の機能追加は mrblib 1 ファイルで完結 + CLI 不要」が実現したが、
**配布側はまだ単一 monolithic wasm**:
`@takahashim/lilac-compiled` に extras も form も全部入っている。

User 要件 (2026-05-23):
- いろんな variant を公式から配布するのは避けたい
- compiled 版についてはコアを 1〜3 種類、あとは plugin として個別配布

問題: 機能の組み合わせ別に compiled wasm を配るとすぐ組合せ爆発する
(`with-extras` / `with-router` / `with-extras-router` …)。これは「runtime
canonical」と「modular 配布」の両立に反する。

mrb_load_irep が `lilac-compiled.wasm` でも完全動作することは §23 完了後に
検証済み (`vm.loadBytecode` API として既に expose 済み)。
これを利用すれば **core wasm を 1 つに保ったまま plug-in を後乗せ**できる。

## 24.3 rationale

- **§23 と完全整合**: plug-in は mrblib 1 ファイル + `register_directive` の
  block 形式。配布時には mrbc で `.mrb` 化するだけで内容は変わらない
- **mrb_load_irep は既に動く**: C / wasm export / JS bridge
  (`vm.loadBytecode`) は実装済み。Lilac 側で `boot({ plugins })` の hook を
  足すだけ
- **mrbc-host.wasm の再利用**: plug-in 作者向け mrbc 経路を別途用意せず、
  既存の `WasmMrbcDriver` をそのまま流用できる (= 「lilac plugin-build」が
  既存 `BytecodeBuilder` の薄いラッパー)
- **variant 爆発回避**: core は 1〜2 個に固定。機能追加は npm package
  追加で表現される

## 24.4 トレードオフ

- **mruby version lock**: plug-in `.mrb` は core wasm に同梱した mruby と
  binary-compatible である必要 (`MRB_BINARY_*` magic / opcode version)。
  npm の `peerDependency` で `@takahashim/lilac-compiled@^X.Y` を強制 +
  mismatched version は `vm.loadBytecode` が `RubyError` を返すので
  ユーザに見える形で失敗する
- **Pure Ruby plug-in のみ**: C 拡張は core wasm に linked 済みでないと
  使えない。Plug-in は `runtime/mruby-*-pure-ruby-only` 制約。第三者が
  C 拡張を含めたい場合は `lilac-compiled` を fork してビルドする必要あり
  (= 公式 plug-in scope 外)
- **Boot 順序の依存**: plug-in は user code より先に load する規約が必須
  (`register_directive` 呼び出しが先に走らないと user component の mount
  時に extension が見つからない)。`boot()` の `plugins:` option で強制
- **Plug-in 内部 API は core の internal に依存**:
  `Lilac::Directives::Scanner.register_directive` の signature が plug-in
  と core で binary-compatible である必要。Core 側の API 変更が plug-in
  package の version bump を強制 (= 適切に semver 管理する)
- **Bundle size 二重カウント**: ユーザの dist には core wasm (~2.9MB) と
  plug-in .mrb (数 KB〜数十 KB) が両方乗る。Tree-shake はできない
  (.mrb 内の不要な class まで含む)。許容範囲

## 24.5 実装

Phase 1: `lilac plugin-build` subcommand (CLI) — 完了

- `cli/lib/lilac/cli/plugin_build.rb`:
  - 入力: `*.rb` ファイル (1 つ以上を結合して compile)
  - 出力: `*.mrb` (mrbc 経由)
  - `BytecodeBuilder#compile_to_bytes` (新規抽出) 経由で既存 mrbc backend
    chain (binary / wasm-driven) を再利用
  - `Lilac.start` は **付加しない** (plug-in は library 扱い)
- `cli/lib/lilac/cli/command.rb`: `plugin-build` subcommand + help を追加
- `cli/test/test_plugin_build.rb`: single / multi input / nested output dir /
  missing input / compile error を網羅

Phase 2: `boot({ plugins })` hook (npm wrapper) — 完了

- `npm/lilac-compiled/index.js`:
  ```js
  if (opts.plugins !== undefined) {
    if (!Array.isArray(opts.plugins)) {
      throw new TypeError("boot: `plugins` must be an array of bytecode buffers");
    }
    for (const p of opts.plugins) {
      vm.loadBytecode(p instanceof Uint8Array ? p : new Uint8Array(p));
    }
  }
  vm.loadBytecode(bytes);  // user code (last)
  ```
- `npm/lilac-full/index.js`: 同等の hook (compatibility のため)
- `index.d.ts`: `BootOptions.plugins` 型定義

Phase 3: `@takahashim/lilac-plugin-extras` package 作成 — 完了

- `npm/lilac-plugin-extras/` 一式 (`package.json` / `index.js` /
  `index.d.ts` / `README.md` / `LICENSE`)。`peerDependency` を **optional**
  にして lilac-full でも使えるよう構成
- `Makefile`: `lilac-plugin-extras` ターゲット +
  `npm-pack` / `npm-clean` 統合
- `.gitignore`: `/npm/**/*.mrb` (build artifact なので tracking しない)
- `build_config/lilac-compiled.rb` から `mruby-lilac-extras` を除外 →
  wasm size 約 20 KB 減

Phase 4: ドキュメント — 完了

- `docs/lilac-plugin-spec.md` 新設 (本決定の how-to を集約)
- `docs/README.md` の仕様レイヤテーブルに `lilac-plugin-spec` を追加
- `docs/lilac-design.md` への "plug-in 配布形態" 節は未着手 — design.md は
  原則レイヤなので、配布形態のような implementation detail は今のところ
  decisions / plugin-spec で十分と判断

Phase 5: E2E parity test — 完了

- `test/parity-fixtures/extras/` 新規 (`data-tooltip` 動作確認用)
- `test/parity-runner.mjs`: `loadCompiled` に `pluginMrbPaths` 引数追加 +
  `SCENARIOS.extras` で extras.mrb を pre-load
- 結果: `lilac-compiled.wasm (extras 抜き) + extras.mrb` が `lilac-full`
  と DOM-byte 一致

Phase 6: router / async plug-in 化 — 完了

- `npm/lilac-plugin-router/` (`Lilac::Router` を提供する class plug-in)
- `npm/lilac-plugin-async/` (`Fetchy` / `Lilac::Resource` を提供する
  class plug-in)
- Makefile target / npm-pack 統合 / `.gitignore` の glob 化 (`/npm/**/*.mrb`)
- build_config 変更なし — 両 gem は元々 lilac-compiled に linked
  されていなかったため、新規 plug-in package 追加のみで完結
- lilac-full は両 gem を引き続き linked のまま (§24.1 の通り)

## 24.6 後続作業 (スコープ外)

- **第三者 plug-in 用テンプレート repo** (cookiecutter 的)。現状は
  `npm/lilac-plugin-extras/` が事実上のテンプレートで、README で構造を
  示すだけで足りる可能性が高い
- **Plug-in registry / discovery** (npm 検索で `lilac-plugin-*` を見つける
  慣習を README で示すだけで十分か、専用 page が必要か)
- **C 拡張 plug-in** が必要になった場合の道筋 (= `lilac-compiled` の fork
  ビルドを公式が用意するか、ユーザに任せるか)
- **Plug-in `.mrb` の hot-reload** (`lilac dev` 統合 or
  `lilac plugin-build --watch`) — proposals.md に proposal 記録済み
- **design.md への "plug-in 配布形態" 節追加** — 当面 decisions §24 +
  plugin-spec で代替

## 24.7 ステータス

**完了 (2026-05-23)**。

Phase 1〜6 すべて main に commit 済み:

| Phase | 内容 | 主要コミット |
|---|---|---|
| 1 | `lilac plugin-build` subcommand | `feat(cli): add lilac plugin-build subcommand …` |
| 2 | `boot({ plugins })` hook | `feat(npm): support boot({ plugins }) …` |
| 3 | extras を plug-in 化 + build_config から除外 | `feat: split extras into @takahashim/lilac-plugin-extras …` |
| 4 | docs (plugin-spec.md 新設) | `docs: document plug-in distribution model …` |
| 5 | E2E parity test | `test(parity): cover lilac-compiled + extras plug-in load …` |
| 6 | router / async plug-in 化 | `feat: add @takahashim/lilac-plugin-router npm package`<br>`feat: add @takahashim/lilac-plugin-async npm package` |

途中で fix した bug (`scan_extensions` trailer の `t.root.to_js` →
`t.to_js`) は `fix(codegen): use t.to_js (not t.root.to_js) for
scan_extensions in iteration scope` で別 commit。
