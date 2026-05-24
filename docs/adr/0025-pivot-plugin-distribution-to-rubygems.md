# 25. Plug-in 配布を rubygems に pivot、npm は `lilac-full` の CDN 配布のみに集約

決定日: 2026-05-23

## 25.1 判断

§24 (plug-in を npm で配布、`lilac-compiled` も npm package として持つ)
を覆し、次のモデルにする:

- **plug-in は rubygems で配布**:
  - `lilac-plugin-extras` / `lilac-plugin-router` / `lilac-plugin-async`
    (それぞれ既存 mrbgem に対応する Ruby gem を新設)
  - gem の中身は **mrblib `.rb` source**。pre-compiled `.mrb` は含めない
  - lilac-cli が **Bundler.load.specs から `metadata["lilac_plugin"]`
    を持つ gem を発見** し、build 時に各 mrblib を `lilac plugin-build`
    相当で `.mrb` に焼いて `dist/plugins/` に stage、生成 boot script に
    `loadBytecode` を inject する
- **`lilac-compiled` wasm は npm 配布しない**:
  - lilac-cli ユーザーは `lilac-wasm-bin` gem (proposals.md 参照) から
    vendor。monorepo 内では `build/lilac-compiled.wasm` を直接使う
  - 非 lilac-cli ユーザーが lilac-compiled を直接扱う path は廃止
    (代わりに Mode 1 = CDN で lilac-full を使う)
- **npm に残るのは `@takahashim/lilac-full` のみ**:
  - 想定する利用形態は **CDN 経由のお試し** のみ:
    ```html
    <script type="module">
      import { boot } from "https://esm.sh/@takahashim/lilac-full";
      await boot();
    </script>
    <script type="text/ruby">
      class App < Lilac::Component
        # ...
      end
    </script>
    ```
  - npm install + bundler 等の Node ecosystem workflow は **想定しない**
    (Mode 1 ユーザーは Node / npm / Vite を一切持たない前提)
- **`lilac dev` 既定 target は `:full`** のまま (canonical で mrbc を経ない
  ので iteration が手軽)
- **`lilac build --target full` でも plug-in が動くようにする**:
  - 現状 `--target full` の dist HTML は `<script type="text/ruby">` を
    残して lilac-full の auto-scan に任せていた
  - plug-in load (`vm.loadBytecode`) を boot 順序に明示挿入するため、
    `--target full` の dist HTML も「明示 boot 形式」に切り替える

## 25.2 背景

§24 を実装し plug-in 機構が完成した直後、ecosystem 配布形態の比較を改めて
行った結果、§24 の npm 経由が Lilac の self-identity と合わないと判明:

| Framework | source 言語 | plug-in 配布 |
|---|---|---|
| SolidJS / Vue / Svelte / Astro | JavaScript | npm (= source 言語の package manager) |
| Jekyll / Bridgetown / Hanami | Ruby | rubygems |
| Phoenix LiveView | Elixir | hex |
| Hugo | Go | go module |
| **Lilac** | **Ruby** | **rubygems** (§25 で確定) |

「source 言語の package manager に従う」が JS 系以外のフレームワーク
共通のパターン。Lilac の source は Ruby、build tool は Ruby gem
(`lilac-cli`)、user の主要 workflow は `bundle exec lilac build` →
**Bridgetown / Jekyll 型の Ruby framework に近い**。

「Vite を使うなら npm」という直感は Lilac には当てはまらない (Lilac は
自前 build pipeline で Vite を経由しない)。

## 25.3 rationale

- **mruby version lock 問題が原理的に消える**: §24 では npm 上の
  pre-compiled `.mrb` と core wasm の mruby バージョンが一致する必要が
  あり `peerDependency` で頑張る設計だった。§25 では plug-in を **手元
  の mrbc-host.wasm でローカル compile** する → core wasm と同じ
  toolchain → 不一致が原理的に発生しない
- **Bundler auto-discovery で zero-config**: `gem "lilac-plugin-extras"`
  を Gemfile に書いてあれば自動。`lilac.config.rb` の明示 `c.plugins`
  設定は advanced override に降格
- **Lilac ecosystem の一貫性**: lilac-cli / lilac-wasm-bin / plug-in
  すべて rubygems に集約。ユーザーの mental model が単純化
- **runtime canonical (§1) は不変**: lilac-compiled wasm を保つことで
  「compiler なし production runtime」は引き続き提供される。npm 配布
  しないだけで仕組みは変わらない
- **Mode 1 (CDN お試し) のシンプルさ**: ユーザーは Node ecosystem 全部
  不要、HTML 1 枚 + `<script type="module">` で動く。Lilac の入口
  ストーリーが最短になる

## 25.4 トレードオフ

- **`--target full` boot 形式の変更**: 現在の auto-scan を明示 boot に
  切り替える必要があり、§20.6 / §20.7 (Pattern A boot helpers) で確立した
  自動 `Lilac.start` の流れと統合し直す必要がある
- **非 lilac-cli ユーザーが plug-in を使う path を提供しない**: §24 では
  npm + `boot({ plugins })` で hand-load する経路を残していたが、§25 では
  廃止。代わりに `gem install lilac-cli` を勧める (Lilac 開発は元々 Ruby
  必須なので前提は変わらない)
- **既に commit 済みの npm/lilac-plugin-* / npm/lilac-compiled を削除**:
  publish 前なので互換性負債はないが、commit log には残る。本節がその
  記録
- **lilac-wasm-bin gem の release 整備が必須**: `lilac-compiled.wasm` を
  ユーザーに届ける唯一の path になるため、gem release flow を実装する
  必要 (proposals.md §「lilac-wasm-bin gem」参照)
- **`@takahashim/lilac-full` npm package の役割が狭まる**: ESM CDN 専用に
  なる。`peerDependency` / `package-lock` を伴う node_modules 設計は
  想定外

## 25.5 実装

Phase A: decision lock (本節)

Phase B: gem infrastructure

- `runtime/mruby-lilac-{extras,router,async}/lilac-plugin-*.gemspec` x3:
  - `spec.metadata["lilac_plugin"] = "true"` で discoverable に
  - `spec.files = Dir["mrblib/**/*.rb", "*.gemspec"]`
- `cli/lib/lilac/cli/plugin_discovery.rb`:
  - `Bundler.load.specs` から `metadata["lilac_plugin"]` 付き gem を返す
  - 各 gem の `mrblib/*.rb` のリストを返す
- `Builder` 統合:
  - `build` の頭で PluginDiscovery を実行
  - 各 gem を `PluginBuild` で compile → `dist/plugins/<gem-name>.mrb`
  - 生成 boot script に inject (両 target)

Phase C: `--target full` plug-in 注入

- dist HTML を明示 boot 形式に統一:
  ```html
  <script type="module" data-lilac-bootstrap>
    import { createVM } from "./vendor/lilac-full/mruby-wasm-js/index.js";
    const vm = await createVM({ wasm: "./vendor/lilac-full/lilac.wasm" });
    vm.loadBytecode(...);  // plug-ins
    vm.evalScript("script[type='text/ruby']");
    vm.eval("Lilac.start");
  </script>
  ```
- 既存の auto-scan 経路は CDN お試し時 (`boot()` helper 経由) でのみ使用

Phase D: npm cleanup

- `npm/lilac-compiled/` 削除
- `npm/lilac-plugin-{extras,router,async}/` 削除
- `npm/lilac-full/index.js` の `boot({ plugins })` hook 削除 (Mode 1 =
  no-plugin の前提に合わせ)
- Makefile から関連 target 削除
- `cli/lib/lilac/cli/compiled_runtime_resolver.rb` から
  `node_modules/@takahashim/lilac-compiled` の lookup path を削除

Phase E: downstream consumers

- `examples/plugin-extras/`: `c.plugins` (path) → `Gemfile` の
  `gem "lilac-plugin-extras"` に書き換え。`README` 全面改訂
- `test/parity-runner.mjs`: `npm/lilac-plugin-extras/extras.mrb` を
  直接参照していたのを、`runtime/mruby-lilac-extras/mrblib/` を
  `lilac plugin-build` で焼いた一時 `.mrb` を使う形に
- `docs/lilac-plugin-spec.md`: §3 (build) / §4 (配布) / §5 (利用) を
  gem-centric に書き換え

Phase F: tests

- PluginDiscovery test (mock Bundler specs)
- Builder integration test (auto-discover + 両 target の boot 注入)
- npm 経路削除に対応した既存 test の更新

## 25.6 後続作業 (スコープ外)

- **wasmtime-rb の `wasm_exceptions` engine option release を待つ**:
  upstream PR
  [bytecodealliance/wasmtime-rb#599](https://github.com/bytecodealliance/wasmtime-rb/pull/599)
  が 2026-05-20 に merge 済みだが、まだ rubygems に release されていない
  (最新 release v44.0.0 は 2026-05-06)。当 release を含む新 version
  (見込み v45 系、2026-06 上旬〜中旬予定) が出たら:
  - `wasm-bin/lilac-wasm-bin.gemspec` の `spec.add_dependency "wasmtime", "~> 44.0"`
    を `"~> 45.0"` (or 該当 version) に bump
  - `cli/Gemfile` の TEMPORARY な local-checkout fallback を削除
  - lilac-cli / lilac-wasm-bin の **公式 release を始める** ことが
    現実的になる (それまでは monorepo の TEMPORARY pin で開発継続)
- **lilac-wasm-bin gem の release 整備**: 現状 monorepo 内には `wasm-bin/`
  スケルトンがあるが、gem release flow (CI で wasm を bundle してから
  publish) は未着手。上記 wasmtime-rb release と連動して着手。
  proposals.md §「lilac-wasm-bin gem」を昇格させる形で別決定として扱う
- **第三者 plug-in テンプレート repo** (引き続き未着手)
- **plug-in registry / discovery 強化** (gem search で `lilac-plugin-*`
  が見つかる慣習 + README ガイドで十分か検証)
- **`lilac dev` の plug-in hot-reload** (proposals.md §「Plug-in .mrb の
  hot-reload」を gem 配布前提に書き換えてから着手)

## 25.7 ステータス

着手 (2026-05-23)。Phase A 完了後、B 〜 F を順次実装。

§24 の sunk cost: §24 を一度全部実装した分のコード (`npm/lilac-plugin-*`
3 つ + `npm/lilac-compiled` の boot hook + Builder の `c.plugins` 配線等)
は Phase D で削除されるが、§24 で確立した **mrblib / register_directive /
scan_extensions / `lilac plugin-build` subcommand / `PluginBuild` クラス**
は §25 でもそのまま使う。失われるのは「**配布チャンネルの選択**」だけで、
plug-in 機構そのものは継続。
