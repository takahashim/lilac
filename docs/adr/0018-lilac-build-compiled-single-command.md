# 18. `lilac build --target compiled` は単一コマンドで deploy 可能な dist を産む

決定日: 2026-05-20

## 問題

`--target compiled` は decisions §17(codegen canonical 化)で `:full` と
DOM 一致するまで仕上がっていたが、**dist が deploy 可能でない** という穴が
2 つあった。

1. **page-inline `<script type="text/ruby">` が silent に dropped される**:
   builder は `.lil` component の script だけを `mrbc` で bytecode 化する。
   `pages/*.html` に直書きされた `<script type="text/ruby">` は extract も
   strip もされず、生 HTML のまま dist に出る。`lilac-compiled.wasm` は
   parser を持たないので **その inline source は実行されず、エラーも出ない**。
   `examples/7guis/` の 5 demo は全て page-inline 方式で書かれており、
   compiled build しても 1 つも動かないという「成功扱いの完全 broken」状態
   だった
2. **`vendor/lilac-compiled/` を populate する経路が無い**: builder の
   bootstrap module は `./vendor/lilac-compiled/index.js` を import するが、
   そこを埋める手段は `public/vendor/lilac-compiled/` への手動 cp 以外
   存在しなかった。さらに、`npm/lilac-compiled/index.js` は `import
   { createVM } from "@takahashim/mruby-wasm-js"` という **bare import**
   を持っており、bundler 無しの project ではブラウザが specifier を resolve
   できず 404 を出す。`runtime-only/` を捨てて `with-cli` 移行を勧める
   doc 体系で「CLI 使う方が壊れる」のは整合性が破綻する

「`lilac build --target compiled` を 1 回叩けば deploy 可能な dist が出る」
ことを compiled target の goal とする(`:full` は元から「open the HTML
file in a browser」で動くので、対称性として `:compiled` も箱で動くべき)。

## 決定

CLI が **runtime provisioning の責務を負う**。具体的には 3 軸の変更を入れる。

### A. Page-inline `<script type="text/ruby">` を bundle + codegen に取り込む

新規 `SFC.extract_inline_ruby_scripts(html)` で page HTML を linear walk して
inline ruby ブロックを抽出。`Builder#build_page` で target に応じて分岐:

- `:compiled` — HTML から `<script type="text/ruby">…</script>` を **strip**
  し、抽出した source を当該 page の `ruby_source` 末尾(component scripts
  の後ろ)に append。content-hash が page 間で同じなら `.mrb` は 1 個に
  dedup される
- `:full` — HTML 内の inline script を **そのまま残す**。runtime parser の
  `vm.evalScript` が拾うので injection を二重化すると重複実行になる

加えて、page HTML に直書きされた `<X data-component="...">` 要素も .lil の
canonical コンポーネントと同じ扱いで **codegen にかける**。`Builder#scan_page_components`
が Nokogiri::HTML5 で fragment を walk し、`<lilac-component>` 由来でない
data-component 要素を **トップレベルも nested も** すべて拾う。各要素を
TemplateAST.parse → Codegen.generate にかけ、生成された `Lilac::Bindings::<Class>`
module を bundle 先頭側に同梱する。

nested data-component は **deep clone した上で内側の data-component の body を
strip** してから TemplateAST に渡す(これで `Crud` の bind_template_hook に
`CrudRow` のディレクティブが leak しない)。nested 自身も別途 codegen 対象に
なるので、`CrudRow` の bind_template_hook は別の module として emit される —
.lil で `crud.lil` + `crud-row.lil` が別ファイルになっていた場合の結果と等価。

compiled の bundle 構成順は `[.lil codegen → .lil user_script → page-inline
codegen → page-inline class 本体 → Lilac.start]`。`Lilac::Bindings::<Class>`
モジュールはユーザクラス定義より前にあるが、`Component#lookup_codegen_bindings`
は mount 時に名前で resolve するので順序は問題ない。

`Lilac.start` の末尾 append は本決定で導入された(compiled wasm は parser を
持たないため page-side で `vm.eval("Lilac.start")` できない — bytecode に
embed する必要がある)。pages-with-no-Ruby のケースだけは empty bundle で
.mrb も bootstrap も emit しない、という gate を維持。

> **註 (2026-05-20)**: 本節の `scan_page_components` を起点とする Nokogiri
> 書き戻し力技は [ADR-19](./0019-codegen-positional-lil-ref.md) で廃止され、
> `synthesize_page_inline_components` (= page-inline subtree を in-memory
> `SFC::Component` として組み立て `<lilac-component>` placeholder に置換) に
> 置換された。page-inline data-component を codegen にかけるという目的は維持。
> 詳細は ADR-19 §影響 / §実装 を参照。

### B. Target-namespaced vendor layout

`public/vendor/` 直下を target ごとに分ける規約を確立:

- `vendor/lilac-full/`     — `lilac-full.wasm` + `mruby-wasm-js/` ブリッジ
- `vendor/lilac-compiled/` — `lilac.wasm` + `index.js` + `mruby-wasm-js/`

`Builder::EXCLUDED_DIRS_FOR_TARGET = { full: ["vendor/lilac-compiled"],
compiled: ["vendor/lilac-full"] }` で **inactive target の subdir を public
mirror から skip**。同じ project が dev=full / prod=compiled を両運用する
ケースで、両 target の asset を `public/` に並べたまま、dist では active
target 側だけが出るようになる。

### C. CLI auto-vendor compiled runtime + inline boot module

`:compiled` build かつ実際に `.mrb` が emit されたとき、`Builder#auto_vendor_compiled_runtime!`
が `dist/vendor/lilac-compiled/` を **自動 populate** する:

1. `lilac.wasm` — binary copy
2. `mruby-wasm-js/*.js` — bridge ファイルを top-level だけ binary copy

そして **boot module は inline で render** する(`render_compiled_boot_module`):

```html
<script type="module" data-lilac-bootstrap>
  import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js";
  const vm = await createVM({ wasm: "./vendor/lilac-compiled/lilac.wasm" });
  const bytecode = new Uint8Array(
    await (await fetch("./app.<hash>.mrb")).arrayBuffer()
  );
  vm.loadBytecode(bytecode);
</script>
```

これは `npm/lilac-compiled/index.js` の boot helper を **vendor しない** という
決定の現れ。npm の helper は bridge の API(`loadIrep` → `loadBytecode` rename 等)
や bare import (`@takahashim/mruby-wasm-js`) で history 上ドリフトしてきており、
CLI が rewrite/sync を続けるよりも、 boot 4 行を builder template として持つ方が
依存面積が小さい。`@takahashim/lilac-compiled` package は「CLI を使わない直接利用」
の道として独立に維持される。

加えて、**compiled の `ruby_source` 末尾に `Lilac.start` を append** する。compiled wasm は
parser を持たないため、page-side で `vm.eval("Lilac.start")` できない(=
bytecode に同梱されている必要がある)。page-inline / `.lil` の user code に
`Lilac.start` が書かれていなくても、builder が必ず最後に 1 行追加する(決定 A
の後段で述べた page-inline codegen と同様に、bundle 完成時に挿入される)。

各 source の **discovery 順**(`bytecode_builder.rb` の mrbc discovery と同じ
段階パターン):

| 段階 | wasm の source | bridge の source |
|---|---|---|
| 1 | `--lilac-compiled-path` CLI flag | `--mruby-wasm-js-path` CLI flag |
| 2 | `c.lilac_compiled_path` config | `c.mruby_wasm_js_path` config |
| 3 | `LILAC_COMPILED_WASM` env | `MRUBY_WASM_JS_PATH` env |
| 4a | `<gem root>/../build/lilac-compiled.wasm`(monorepo dev build)| `<gem root>/../mrbgem/mruby-wasm-js/js/`(monorepo)|
| 4b | `<gem root>/../npm/lilac-compiled/lilac.wasm`(monorepo の最後の npm-pack 成果物)| — |
| 5 | `<project>/node_modules/@takahashim/lilac-compiled/lilac.wasm` | `<project>/node_modules/@takahashim/mruby-wasm-js/` |
| 6 | — | `<project>/node_modules/@takahashim/lilac-compiled/node_modules/@takahashim/mruby-wasm-js/`(nested fallback)|

monorepo の wasm 検出が **build/ 優先 → npm/ fallback** なのは、`npm/lilac-compiled/lilac.wasm`
が `-flto` 入りで build された時代の成果物を carry しており、`env.setjmp` / `env.longjmp`
の未解決 import を残してブラウザ instantiation 時に `LinkError: function import requires
a callable` で落ちるケースがあるため。現 `build_config/lilac-compiled.rb` は `-flto`
を外しており、`make lilac-compiled` で作る `build/lilac-compiled.wasm` は env import を
持たない(= 現 bridge と整合する)。

> **註 (2026-05-23)**: 本 discovery table は [ADR-25](./0025-pivot-plugin-distribution-to-rubygems.md)
> で再編された。`@takahashim/lilac-compiled` の npm 配布は廃止、`lilac-wasm-bin`
> gem 経由の配布に統一されたため、段階 4b (`npm/lilac-compiled/lilac.wasm`) と
> 段階 5/6 (`node_modules/@takahashim/...`) は **削除済み**。現在の段階順は次:
>
> | 段階 | wasm | bridge |
> |---|---|---|
> | 1 | `--lilac-compiled-path` / `c.lilac_compiled_path` | `--mruby-wasm-js-path` / `c.mruby_wasm_js_path` |
> | 2 | `LILAC_COMPILED_WASM` env | `MRUBY_WASM_JS_PATH` env |
> | 3 | **`lilac-wasm-bin` gem** (canonical install path) | **`lilac-wasm-bin` gem** |
> | 4 | monorepo `build/lilac-compiled.wasm` | monorepo `mrbgem/mruby-wasm-js/js/` |
>
> 実装 SSOT は `cli/lib/lilac/cli/compiled_runtime_resolver.rb`。

boot helper は npm package の `index.js` を vendor せず、builder template として
`render_compiled_boot_module` で inline 出力する(上記決定 C 参照)ので、boot helper
の discovery 経路は不要。

全段失敗時は **build error**(具体的な fix 案 4 つを表示)。silent 失敗は
させない — `mrbc not found` と同じ severity。

## 影響

- `examples/7guis/` を例にすると、`lilac build --target compiled` → `dist/`
  に **6 HTML + 6 per-page `.mrb`(content-hash dedup)+ vendor/lilac-compiled/
  一式** が出て、`python3 -m http.server --directory dist` で 5 demo が
  全部動く
- `public/vendor/lilac-compiled/` への手動 cp 指示が完全廃止 — 新 project は
  `npm install @takahashim/lilac-compiled` だけで OK(monorepo 開発時は env も
  config も不要)
- target=full の出力バイト列は完全不変(inline extraction を skip、auto-vendor
  を skip)。後方互換 100%
- `:compiled` の auto-vendor 仕組みは **`:full` 側にも同じ規約を後付けで
  適用しやすい** — 別 PR で対称化予定(本 §18 では scope 外)

## 反映先 spec

- 本 § が SSOT
- `docs/lilac-workflow.md` の "target ごとの vendor 配置と自動 prune" 節
  (target-aware exclusion 部分)を更新済み。auto-vendor の振る舞いは
  CLI README (`cli/lib/lilac/cli/templates/README.md`)に転記
- `cli/lib/lilac/cli/compiled_runtime_resolver.rb` の class doc が
  discovery 経路の実装上 SSOT

## 実装

- `cli/lib/lilac/cli/sfc.rb`: `extract_inline_ruby_scripts` 追加(public API)
- `cli/lib/lilac/cli/builder.rb`:
  - `build_page` で inline 抽出 + target=compiled で strip
  - `scan_page_components` 新設(Nokogiri::HTML5 で page HTML を walk、
    nested data-component も収集、各々を TemplateAST + Codegen にかける)
  - `build_injection` に `page_inline_scripts:` / `page_components:` /
    `page_path:` キーワード追加。生成された Bindings module + 同梱の
    synthetic templates(data-each row 用)を injection に乗せる
  - `render_compiled_boot_module` を rewrite — npm 配布版 `index.js` への
    import を捨てて、bridge を直接呼ぶ self-contained module を emit
  - `auto_vendor_compiled_runtime!` 新設、`build` 後段で target=compiled かつ
    `.mrb` 存在時のみ呼ぶ(wasm + bridge を copy、`index.js` は inline emit
    のため不要)
  - `:compiled` の bundle 末尾に `Lilac.start` を自動 append
  - `EXCLUDED_DIRS_FOR_TARGET`(target-namespaced public mirror)
- `cli/lib/lilac/cli/compiled_runtime_resolver.rb` 新規: 6 段階 discovery を
  `bytecode_builder.rb` パターンで実装。monorepo 検出は gem の `__dir__` 4
  段親から(`File.expand_path("../../../..", __dir__)`)。monorepo の wasm 候補は
  `build/lilac-compiled.wasm`(`make lilac-compiled` 成果物)→ `npm/lilac-compiled/lilac.wasm`
  の順で、前者が古い `-flto` ビルドの env.setjmp 問題を踏まないようになっている。
  boot helper は wasm 検出と独立に走らせ、wasm 隣に index.js が無い構成(`build/` 配下)
  にも対応する。tests は `monorepo_root:` 注入で gem 位置に依存しない
- `cli/lib/lilac/cli/config.rb` + `config_loader.rb`: `lilac_compiled_path` /
  `mruby_wasm_js_path` を `Config` と `Settings` に追加
- `cli/lib/lilac/cli/command.rb`: `--lilac-compiled-path` / `--mruby-wasm-js-path`
  flag 追加、`Config.load` + `Builder.new` に pass-through
- `cli/lib/lilac/cli/dev_server.rb`: 同様の pass-through
- `cli/lib/lilac/cli/doctor.rb`: `RUNTIME_WASM` / `RUNTIME_JS_ADAPTER` の
  期待 path を namespaced layout に更新
- `cli/lib/lilac/cli/templates/{lilac.config.rb, pages/index.html, README.md}`:
  scaffold が namespaced layout + auto-vendor の前提で書かれるよう更新
- `cli/test/test_sfc.rb`(+5), `cli/test/test_builder.rb`(+9: target-aware
  exclusion 3 + inline 5 + auto-vendor 4 + 1 combine), `cli/test/test_compiled_runtime_resolver.rb`
  新規(12)。total 382 runs, 1051 assertions, all green

## 18.5 Refinement: `lilac build` の既定 target を `:compiled` に(2026-05-20)

§18 着地時は `lilac build` の既定 target が `:full` だった(`lilac dev` と
対称的に同じ default、user が production 用には `--target compiled` を
明示する設計)。しかし以下の理由で **既定を `:compiled` に変更**:

- `lilac build` の主用途は **production deploy**。production は基本
  `:compiled` の方が小さい bundle と faster boot を得られる
- `lilac dev` (既定 `:full`、mrbc 不要) と `lilac build` (既定 `:compiled`、
  mrbc 必要) で **Vite-style の dev/prod 二段構え** が明示的に成立する
- decisions §1 「ビルド不要で動くこと」の精神は `lilac dev` で保たれる
  (mrbc は依然 dev で不要)。`lilac build` だけが prod deploy 時の追加
  setup を要求するのは妥当

mrbc 不要で `lilac build` を回したい場合は `--target full` を明示する
escape hatch を残す。これは debug 用途 / mrbc セットアップが間に合わない
環境で有用。

### 影響を受ける箇所

- `cli/lib/lilac/cli/config.rb`: `DEFAULT_BUILD_TARGET` を `:full` → `:compiled` に変更
- `cli/lib/lilac/cli/command.rb#print_next_steps`: `lilac new` の scaffold message に
  「ship 時は `lilac build`(compiled デフォルト)、mrbc-free が必要なら
  `--target full`」を追記
- `cli/lib/lilac/cli/templates/README.md`: scaffold README の build 例を更新
- `cli/README.md`, `docs/lilac-workflow.md`: build 既定の説明を更新
- `cli/test/test_command.rb`: 5 件の `lilac build` invocation に `--target full`
  を明示(mrbc-free のままテストを通すため)

CLI tests 393 all green、CLI 配下以外への影響なし。

---
