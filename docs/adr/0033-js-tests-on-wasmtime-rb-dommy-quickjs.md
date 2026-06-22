# 33. JS 依存テストを wasmtime-rb + Dommy(quickjs)へ移行

決定日: 2026-05-31

## 判断

Lilac のテストの JS 実行を **Dommy + dommy-js-quickjs(QuickJS を Dommy DOM に
バインドした実 JS エンジン)** に寄せる。`make test`(wasmtime-rb ホスト)の JS
ブリッジを、簡易 JS 評価器 + 手書き async スタブから **本物の QuickJS イベント
ループ**へ置換し(Phase 1)、これまで Node 専用だった JS ホスト統合テスト
(bundle boot / :full×:compiled parity)を **Ruby spec として再表現**する
(Phase 2)。Node + happy-dom 経路は V8 固有 GC のクロスチェックとして残す。

## 背景

テストは 2 ホストで走っていた:

| runner | host | DOM | 役割 |
|---|---|---|---|
| `make test-wasm-rb` | wasmtime-rb | Dommy(Ruby 製 DOM polyfill) | 速い内ループ |
| `make test-node` | Node/V8 | happy-dom | CI。V8 固有 bug |

`runtime/*/wasm_spec/` の全ファイルは両 runner で走っていたが、Dommy は JS 非実行
のため async 系を **Ruby スタブで近似**していた(`spec_runner.rb` の
`drain_async!`、MutationObserver / Promise / setTimeout の擬似進行)。また bundle
boot(ADR-0030)と :full×:compiled parity の 2 本は mruby-wasm-js JS ブリッジ +
`fetch` + `DOMParser` を要するため **Node 専用**だった。

スタブと実 JS の乖離リスク、および JS 統合契約が Node 必須という制約があった。
`dommy-js-quickjs`(Dommy に QuickJS ベースの JS 実行を統合)が整い、この棲み
分けを縮められるようになった。

## rationale

- **忠実度**: async / Promise / microtask / MutationObserver の順序が、近似
  スタブではなく実イベントループで V8 相当になる。data-each の行挿入や dynamic
  mount の検出順序が本物になる。
- **スタブ保守コスト減**: 手書きの `drain_async!` 擬似進行を実 `run_until_idle`
  に縮退できる。
- **単一 runner で大半をカバー**: Node なし CI でも bundle / parity 契約を回せる。
- **ブリッジ経由の単一 JS 世界**: QuickJS が `globalThis` を所有し Dommy を install。
  guest(mruby-on-wasm)の `js_*` import を QuickJS に集約することで、ブリッジの
  挙動も Ruby 経路で踏める。
- **Node 経路は完全置換しない**: QuickJS ≠ V8。`FinalizationRegistry` timing 等の
  V8 固有 GC 挙動はクロスチェックとして Node smoke を残すのが妥当。

## トレードオフ

- **ネイティブ拡張依存**: `dommy-js-quickjs` は `quickjs` ネイティブ拡張をビルド
  するため、内ループの Ruby テスト経路に C toolchain が必要になった。
  `LILAC_JS_ENGINE=dommy-stub` で旧スタブ(ビルド不要・低忠実度)へフォールバック可。
- **ホスト DOM の自前実装に依存**: Dommy / makiri(Lexbor ベース backend)の
  挙動が Lilac テスト結果を左右する。実際、ポインタ identity 再利用による
  wrapper-cache 汚染バグ(data-each の行追加が反映されない)を踏み、Dommy 側で
  修正した(`NodeWrapperCache#wrap` の nodeType 検証)。
- **重い統合テスト**: Ruby 版 bundle / parity は両 wasm ターゲットをビルドする
  ため、デフォルト `rake test` からは除外(`test-bundle-rb` / `test-parity-rb`
  で個別実行、`test-all` に統合)。

## 実装

完了 (2026-05-31、Phase 1 + Phase 2)。`dommy` 0.9.0 + `dommy-js-quickjs` 0.9.0
(makiri backend)で JS 実行基盤が整い、Lilac の wasmtime-rb 経路で本物の JS が走る。

- **配線**: `test/ruby_spec/mruby_wasm.rb` の ~25 個の `js_*` import を QuickJS に
  集約(QuickJS が単一の JS 世界、Dommy を install)。dommy-js-quickjs に wasm
  ホスト向けハンドル指向 API(`__rbHost.wasm*` + `Runtime#wasm_bridge`)。Lilac 側
  は `test/ruby_spec/quickjs_bridge.rb`(`JsRef` が `__js_*` ABI を実装し既存
  ダックタイピング dispatch に乗る)。`LILAC_JS_ENGINE=dommy-stub` で旧スタブへ。
- **Phase 1**: 簡易 JS 評価器 + 手書き `drain_async!` を QuickJS eval +
  `run_until_idle` に置換。`wasm_spec/` 全ファイルが両エンジンで結果一致
  (`make test-wasm-rb` 既定 = QuickJS)。
- **Phase 2**: `cli/test/test_bundle_runtime.rb`(ADR-0030 boot)/
  `cli/test/test_parity.rb`(:full×:compiled DOM 一致)を追加。`make test-bundle-rb`
  / `test-parity-rb` で実行、`test-all` に統合。既存 `.mjs`(`make test-node`)は
  V8 固有 GC のクロスチェックとして残す。

## 後続作業

- **gem 依存の切替(未完)**: 現状 `cli/Gemfile` は `dommy` / `dommy-js-quickjs` /
  `makiri` を sibling clone の `path:` で参照。各 gem の公開後に published 版へ
  pin し、`path:` ブロックを外す(CI が published gem で `make test` を回せる状態)。
- **CI への dommy 系の供給**: `test.yml` は現状 mruby-wasm-runtime / wasmtime-rb
  のみ sibling checkout。published 版切替に合わせて CI 経路を確定する。

## ステータス

完了 (2026-05-31、Phase 1 + Phase 2)。gem 依存の published 版切替のみ後続作業
として保留(Dommy 系の rubygems 公開待ち)。

## 関連

- [ADR-0030](./0030-bundle-delivery-via-lilac-bundle-link.md) — bundle boot の
  runtime 契約。Phase 2 で Dommy 化した対象
- [ADR-0029](./0029-data-component-data-use-split.md) — data-use 展開。runtime
  spec は Dommy / Node 両方で green
- [ADR-0031](./0031-scanner-canonical-binding.md) — new-EH wasm を host で動かす
  wasmtime v45 の `wasm_exceptions` が前提
