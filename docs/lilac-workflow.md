# Lilac 開発ワークフロー

Lilac は **Vite 流の dev/prod 二段構え** を採用している(decisions §17)。
**dev は速さ重視、prod はサイズと攻撃面重視**。同じ `.lil` source から両方の
出力をビルドできる。

このドキュメントは「Lilac でアプリを書く側」向けの実用ガイド。設計判断の
背景は [`lilac-decisions.md`](./lilac-decisions.md) §15・§17 を参照。

---

## TL;DR

```bash
gem install lilac-cli       # ← 仮 (現状は repo clone + bundle exec)
lilac new my-app            # プロジェクトを作る
cd my-app
lilac dev                   # 開発サーバ起動 → http://127.0.0.1:5173
                            # `.lil` を保存すると SSE でブラウザ自動リロード
lilac build                 # dist/ に出力(既定 target=compiled、mrbc 必要)
lilac build --target full   # mrbc 不要、runtime parser を dist に同梱
```

---

## ファイル構造

`lilac new` が作る雛形:

```
my-app/
├── lilac.config.rb        # 設定(全 field optional)
├── Gemfile
├── components/
│   └── counter.lil        # SFC: <template> + <script type="text/ruby">
├── pages/
│   └── index.html         # <lilac-component name="counter"></lilac-component> を置く
└── public/                # 画像 / vendor wasm / 静的ファイル
```

build 後:

```
my-app/dist/
├── index.html             # pages の HTML を展開 + 必要な script を inline
└── ...                    # public/ の中身がコピー、必要なら vendor/lilac-*/ も
```

---

## 二つの build target

| target | 何が違うか | 用途 |
|---|---|---|
| **`full`**(既定) | mruby parser + runtime scanner を bundle した wasm(`lilac-full.wasm`、brotli ~322 KB)。`<script type="text/ruby">` を inline emit、ブラウザ側で `vm.evalScript()` | 開発(`lilac dev`)、prototype、CLI を介さず HTML 直書きで試したいとき |
| **`compiled`** | `mrbc` で precompile した `.mrb` bytecode + parser を抜いた小さい wasm(`lilac-compiled.wasm`、brotli ~175 KB)。ブラウザは `boot({ bytecode })` で起動 | production、bundle size を絞りたいとき、parser 由来の脆弱性面を消したいとき |

両者で **DOM 出力は完全一致**(`test/parity-runner.mjs` で継続検証)。
binding は両 target とも codegen が行う(decisions §17)。

### いつ compiled に切り替えるか

- production deploy する直前
- 公開する `dist/` の bundle size を気にしているとき
- `mrbc` バイナリが手元にある or `MRBC` env で指せるとき(後述)

dev は **常に `full`** で問題ない(mrbc を kick する 100-200ms 分の latency を
避けられる)。

---

## `lilac dev`(開発ワークフロー)

```bash
lilac dev                          # 既定: 127.0.0.1:5173、target=full
lilac dev --port 8000              # ポート指定
lilac dev --host 0.0.0.0           # 外部からも見られる
lilac dev --target compiled        # 稀: compiled で dev する(mrbc 必要)
```

### 何が起きるか

1. **wsv**(Ruby 製静的ファイルサーバ)が起動して `dist/` を serve
2. `components/` と `pages/` を watch
3. ファイル保存 → 自動 rebuild → **SSE 経由でブラウザに reload 通知**
4. ブラウザは reload してビルド済み HTML を再取得

dev 中は `dist/` がライブ更新される。手で `lilac build` する必要なし。

### dev で `target=compiled` を使うケース

prod ビルドの動作を手元で完全再現したいときだけ。通常は不要。

---

## `lilac build`(本番ワークフロー)

```bash
lilac build                        # 既定: target=compiled、output=dist (mrbc 必要)
lilac build --target full          # mrbc 不要、runtime parser を dist に同梱
lilac build --mrbc-path /path/to/mrbc      # mrbc を明示(compiled target で使用)
lilac build -o public_html         # 出力先を変える
lilac build --no-clean             # 既存 dist を残して上書き build (incremental)
```

> **既定 target が `:compiled`** なのは production deploy が `lilac build`
> の主用途で、`:compiled` の方が bundle が小さく runtime parser を含まない
> ため(decisions §18)。`lilac dev` の既定は `:full` のままなので、開発
> ループは mrbc 不要のままで進められる(Vite-style の dev/prod 二段構え)。

> **注**: `lilac build` は **既定で output_dir を build 前に wipe する**(Vite /
> Next / Eleventy と同じ慣習)。古い `app.<hash>.mrb` 等の累積を防ぐため。
> dist に外部から置いたファイルを残したい場合は `--no-clean` を明示。
> project root / `$HOME` / `/` への `--clean` は safety guard で refuse される。

### target=full の出力

`dist/index.html` に:
- `<template>` + `data-component=...` の展開済み markup
- `<script type="text/ruby">` で生成された Ruby コード(codegen
  `Lilac::Bindings::<Class>` モジュール + user_script を結合)
- ブラウザ側で `lilac-full.wasm` をロードして `vm.evalScript()` で実行

### target=compiled の出力

`dist/` に:
- `index.html`(template markup のみ、`<script type="text/ruby">` なし)
- `bundle-<hash>.mrb`(mrbc で precompile した bytecode、content-hash でキャッシュ無効化)
- `<script type="module" data-lilac-bootstrap>` が embed され、bytecode を fetch して `boot({ bytecode })` を呼ぶ

別途 **`@takahashim/lilac-compiled` npm package** を `public/vendor/lilac-compiled/` に置く必要がある(boot helper + wasm)。

### target ごとの vendor 配置と自動 prune

`public/` は build 時に `dist/` へまるごとミラーされるが、target 別の wasm asset
は名前空間化されたサブディレクトリに置くと CLI が自動で inactive target 側を
除外する:

- `public/vendor/lilac-full/`     — `lilac-full.wasm` + `mruby-wasm-js/`
- `public/vendor/lilac-compiled/` — compiled boot helper + wasm

`lilac build --target full` 時は `vendor/lilac-compiled/` を、`--target compiled`
時は `vendor/lilac-full/` を skip する。dev=full / prod=compiled を同じ
project で運用する場合は両方を `public/` に並べておけばよい。実装は
`Builder::EXCLUDED_DIRS_FOR_TARGET`(`cli/lib/lilac/cli/builder.rb`)を参照。

### mrbc の場所

`--target compiled` 時に `mrbc` バイナリが必要。優先順位:

1. `--mrbc-path` CLI フラグ
2. `lilac.config.rb` の `c.mrbc_path = "..."`
3. `MRBC` 環境変数
4. `MRUBY_WASM_RUNTIME_PATH/mruby/build/host/bin/mrbc`(mruby-wasm-runtime
   を sibling repo として使っている場合の自動検出)
5. `$PATH`

---

## `lilac.config.rb`

すべての項目 optional。CLI フラグが優先。

```ruby
Lilac::CLI.configure do |c|
  # パス
  # c.components_dir = "components"
  # c.pages_dir      = "pages"
  # c.public_dir     = "public"
  # c.output_dir     = "dist"

  # dev サーバ
  # c.dev_host = "127.0.0.1"
  # c.dev_port = 5173

  # ビルド target
  # c.dev_target   = :full        # `lilac dev` の既定 target
  # c.build_target = :full        # `lilac build` の既定 target。prod は :compiled に
  # c.mrbc_path    = nil          # 明示する場合だけ
end
```

例: prod ビルドだけ compiled、dev は full に固定したい:

```ruby
Lilac::CLI.configure do |c|
  c.dev_target   = :full
  c.build_target = :compiled
end
```

---

## CLI コマンド一覧

| コマンド | 用途 |
|---|---|
| `lilac new <name>` | プロジェクト雛形を作る |
| `lilac dev` | 開発サーバ起動 + watch + SSE reload |
| `lilac build` | dist/ にビルド |
| `lilac doctor` | 依存ツール(mrbc、mruby-wasm-runtime)の検出 |
| `lilac help` | ヘルプ表示 |

各コマンドの詳細フラグは `lilac help <cmd>` で確認(`add_target_options` /
`add_path_options` を参照)。

---

## デプロイ

`dist/` を静的ファイルとして配信できる場所(GitHub Pages、Cloudflare Pages、
Netlify、S3、nginx、wsv …)に置くだけ。

target=compiled の場合、`.mrb` ファイルの **MIME type** に注意:

- 多くの static host は `application/octet-stream` を返す → OK
- `application/wasm` ではない(`.mrb` は wasm ではなく mruby bytecode)
- 拡張子マッピングを書ける host (`.htaccess` / nginx の `types`) では
  `application/octet-stream` を明示すると安全

content-hash 付きファイル名(`bundle-<sha>.mrb`)なので **長期キャッシュ可**。
`Cache-Control: public, max-age=31536000, immutable` で配ってよい。

`index.html` は **キャッシュ短め**(`max-age=0` か小さい数字)を推奨。中身に
content-hash が埋まっているので、`.mrb` が変わると `index.html` も変わる。

---

## 関連 doc

- [`lilac-decisions.md`](./lilac-decisions.md) §15(`lilac-full` の bundle size 最適化)
- [`lilac-decisions.md`](./lilac-decisions.md) §17(binding canonical = codegen、scanner = grammar reference)
- [`lilac-spec.md`](./lilac-spec.md) Build size 節(各 variant のサイズ表)
- `cli/lib/lilac/cli/builder.rb` / `bytecode_builder.rb`(実装の SSOT)
