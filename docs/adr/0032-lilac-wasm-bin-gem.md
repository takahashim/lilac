# 32. `lilac-wasm-bin` gem で rubygems から `lilac build` まで完結させる

決定日: 2026-05-29

## 判断

Lilac の wasm ランタイム群(`lilac-full.wasm` / `lilac-compiled.wasm` /
compiler-only の `mrbc-host.wasm`)と JS ブリッジ(`mruby-wasm-js`)を **単一の
`lilac-wasm-bin` gem に同梱**して配布する。`lilac-cli` はこの gem を discovery
し、`gem install` + `bundle install` だけで `lilac dev` / `lilac build`
(default `--target compiled`)が npm / C toolchain なしで動く状態にする。

## 背景

`lilac-cli` 単体では `lilac build`(既定 `:compiled`、ADR-0018)が動かず、
3 種の外部依存が必要だった:

| 必要物 | 旧配布元 | rubygems で揃う? |
|---|---|---|
| `mrbc` バイナリ | mruby host build | ❌ |
| `lilac-compiled.wasm` | npm `@takahashim/lilac-compiled` | ❌ |
| `mruby-wasm-js` JS ブリッジ | npm | ❌ |

ADR-0001 の「ビルド不要で動く」精神は `lilac dev`(`:full`)で守られるはず
だが、実際には dev も build も追加 setup を要求し、Ruby 開発者に npm + C
toolchain の知識を強いていた。ADR-0028 で npm 配布を全廃したため、rubygems
単独で完結する配布路が必要になった。

## rationale

- **`mrbc` を専用 compiler wasm で置換**: `mrbc` は実質「mruby parser +
  compiler + bytecode dump」の CLI 化にすぎない。compiler-only の
  `mrbc-host.wasm`(reactor module)を用意し、`lilac-cli` の
  `WasmMrbcDriver` が **wasmtime-rb 経由**で `compile_source` を叩くことで、
  外部 `mrbc` バイナリも platform 別 `mrbc-bin` gem も不要になる。`.rb` →
  `.mrb` は同一 wasm で deterministic / platform 非依存。

  > 当初提案は `lilac-full.wasm` を mrbc として兼用する案だったが、実装では
  > **compiler だけを切り出した小さな `mrbc-host.wasm`**(`mruby-compiler` +
  > `mruby-bin-mrbc` 相当、`runtime/mruby-host-compile` の `compile_source`
  > ABI)に分けた。full wasm は browser-only 最適化(ADR-0015)で size を削っ
  > ており compiler を積まないため、build 専用の compiler 表面を別 wasm に
  > 分離する方が責務が綺麗で size も小さい。

- **単一 gem で version coherence**: full / compiled / mrbc-host を 1 gem に
  まとめることで、release timing でバージョンが必ず一致する。npm artifact が
  古いまま fallback されて壊れる問題が構造的に起きえない。
- **wasmtime-rb 採用**: wasmer-ruby と機能同等だが、Bytecode Alliance 製で
  ruby.wasm 系の実績があり、v45 で `Engine.new(wasm_exceptions:)` を expose
  する(ADR-0031 の new-EH wasm を host で動かすのに必須)。
- **統合 gem(分離しない)**: `lilac-full` と `lilac-compiled` を別 gem に
  する動機は薄く、統合で install simplicity と release coherence を得る。

## トレードオフ

- **gem サイズ ~6MB**(wasm 3 種同梱)。Ruby gem としては大きめだが
  `sass-embedded` クラスの前例があり許容範囲。dev 専用 user が compiled /
  mrbc-host wasm も pull する cost は disk のみ。
- **mruby-wasm-runtime との release 同期**: gem の wasm は
  mruby-wasm-runtime の特定 commit からビルドされるため、両者の release
  同期 flow が必要。
- `mrbc-host.wasm` という build 専用 artifact が 1 つ増える(が full の
  size を犠牲にせず compiler 機能を提供できる対価)。

## 実装

完了 (2026-05、commits `bc78a7e` → `4319ceb` → `b9ad304` → `27bfade`)。

- **`wasm-bin/`(`lilac-wasm-bin` gem)**: `data/` に `lilac-full.wasm` /
  `lilac-compiled.wasm` / `mrbc-host.wasm` / `mruby-wasm-js/` を同梱。
  `lib/lilac/wasm/bin.rb` が `lilac_full_wasm` / `lilac_compiled_wasm` /
  `mrbc_host_wasm` / `mruby_wasm_js_dir` を公開(gem `data/` → monorepo
  `build/` の fallback discovery 付き)。gemspec で `add_dependency
  "wasmtime", "~> 45.0"`。
- **`runtime/mruby-host-compile/`**: `compile_source(src_ptr, src_len,
  out_ptr_ptr, out_len_ptr, err_ptr_ptr, err_len_ptr)` ABI を export する
  compiler reactor(`src/host_compile.c`)。`build_config/mrbc-host.rb` で
  ビルド。
- **`cli/lib/lilac/cli/build/wasm_mrbc_driver.rb`**: `mrbc-host.wasm` を
  `Wasmtime::Engine`(`wasm_exceptions: true`)で load し `compile_source` を
  invoke、engine instance を 1 build 中再利用。`available?` で
  wasmtime-rb 可用性 + 必須 export を検査。
- **`compiled_runtime_resolver.rb` / `bytecode_builder.rb`**: discovery 順序
  に gem 経由 path を追加(config / env の後)。`gem_provided_wasm` で
  `Lilac::Wasm::Bin` を soft-require。
- **`doctor.rb`**: lilac-wasm-bin gem / compiled wasm / mrbc backend の
  可用性チェック。
- **scaffold**: `lilac new` の Gemfile / README が `lilac-wasm-bin` を宣言。

## 後続作業

- **Auto-fallback(Part 2、未実装)**: `lilac build --target compiled` が
  必要物を解決できない時に `:full` へ自動 fallback + warn する mode
  (opt-in `--allow-target-fallback`)。補助機能なので需要が出た時点で後付け。
- gem name の最終確定(`lilac-wasm-bin` で確定運用中)。
- mruby-wasm-runtime ↔ lilac-wasm-bin の release 同期 flow の整備。

## ステータス

完了 (2026-05)。Part 1(gem + WasmMrbcDriver + resolver/doctor 統合)は
出荷済み。Part 2(auto-fallback)のみ後続作業として保留。

## 関連

- [ADR-0001](./0001-runtime-canonical.md) — 「Runtime canonical / CLI optional」。
  本 ADR は "optional" を install 摩擦の意味でも実現
- [ADR-0015](./0015-lilac-full-bundle-size-optimization.md) — full wasm の
  browser-only 最適化。compiler を full に積まない判断が mrbc-host 分離の前提
- [ADR-0018](./0018-lilac-build-compiled-single-command.md) — 既定 `:compiled`。
  これで install 摩擦が build 経路に顕在化、本 ADR で吸収
- [ADR-0028](./0028-drop-npm-distribution-github-pages-cdn.md) — npm 配布全廃。
  rubygems 単独完結の必要性を生んだ
- [ADR-0031](./0031-scanner-canonical-binding.md) — new-EH wasm。host で動かす
  wasmtime v45 の `wasm_exceptions` が前提
