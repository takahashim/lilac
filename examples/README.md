# Lilac examples

ここには Lilac の使い方を示す 2 種類の demo が並んでいる。**どちらも同じ
ランタイム**で動くが、開発フロー(ビルドの有無、CLI を通すか)が違う。
学習や移植の方向に合わせて選ぶ。

## レイヤと使い分け

| ディレクトリ | 何を示すか | ビルド | いつ読むか |
|---|---|---|---|
| [`cdn-runtime-only/`](./cdn-runtime-only/) | GitHub Pages 上の Lilac CDN を `import` するだけで動く最小例。ローカルファイル参照なし、静的ホストにそのまま置ける | 不要 (HTML 直書き) | 「外部サイトに Lilac を載せたい」「CDN から配信したい」「セットアップなしで触りたい」 |
| [`runtime-only/`](./runtime-only/) | ノービルドの **ランタイム canonical** パス。各 HTML が `<script type="text/ruby">` を inline で持ち、`../../build/lilac-full.wasm` を直接ロードする | 不要 (HTML 直書き) | 「ビルドツールなしで Lilac を試したい」「runtime の振る舞いを直接確認したい」「README の Quick start から辿ってきた」 |
| [`7guis/`](./7guis/) | [7GUIs](https://eugenkiss.github.io/7guis/) ベンチを Lilac で実装した gallery。`lilac-cli` で `pages/*.html` と 1 つの shared `components/gallery-nav.lil` をビルドする | `bundle exec lilac build` | 「実プロジェクト構成の reference が欲しい」「`lilac-cli` のフローを見たい」「他フレームワークと書き味を比較したい」 |

`7guis/` は CLI のフロー全体(`pages/` + 共有コンポーネント + `public/` 静的 passthrough + `lilac dev` の watch / reload)を見せる位置付け。**`.lil` SFC は 1 ファイルだけ** — 全 8 ページで再利用する `gallery-nav.lil` のみ。残りの task widget は各 page に inline で書く形にして、「`.lil` は **複数ページで markup を共有したい** ときに切り出すもの」という方針を実例で示している。

加えて、`7guis/lilac.config.rb` では **`c.delivery = :bundle`** を指定し、共有 `gallery-nav` の定義を全ページで個別 inline するのではなく、`dist/lilac.bundle.html` という 1 つのファイルに集約して `<link rel="lilac-bundle">` で参照する形を選んでいる。これにより各 page HTML が小さくなり、`gallery-nav.lil` 更新時のキャッシュ invalidate も bundle ファイル単位で済む。

## runtime-only/

```bash
# repo root で
make serve            # lilac-full.wasm をビルド + wsv で配信
open http://127.0.0.1:8000/examples/runtime-only/
```

各 `lilac-*.html` は単体で完結している。コピーして書き換えれば別アプリの
雛形になる。`../../build/lilac-full.wasm` と `../../mrbgem/mruby-wasm-js/js/index.js`
を参照しているので、repo の外に持ち出すときはパスを書き換える。

## 7guis/

[7GUIs](https://eugenkiss.github.io/7guis/) は GUI フレームワーク比較の
ベンチ。7 タスクのうち 5 つ(Counter / Temperature Converter / Flight
Booker / Timer / CRUD)を実装済み。残り 2 つ(Circle Drawer / Cells)は
未実装で、`pages/index.html` 上で TBD として表示している。

```bash
cd examples/7guis
bundle install                    # path: ../../cli の lilac-cli を解決
# 初回 + wasm 更新時: wasm と JS bridge を public/vendor/ に sync (gitignore 対象)
make -C ../.. examples-vendor-full
# 開発
bundle exec lilac dev             # http://127.0.0.1:5173
# 本番ビルド
bundle exec lilac build           # → dist/
```

`examples-vendor-full` target は `examples/*/public/vendor/lilac-full/` を持つ
全 example に対して `build/lilac-full.wasm` と `mrbgem/mruby-wasm-js/js/` の
最新コピーを同期する。`make clean` した後や lilac の wasm を rebuild した
後に走らせる。`lilac-cli` の build フローには **意図的に組み込まない** —
ビルダーは monorepo 固有のレイアウトを知らないので、責務分離として
Makefile 側に閉じ込めている (production user は `lilac-wasm-bin` gem を
経由する将来の経路を使う想定)。

`Gemfile` は `gem "lilac-cli", path: "../../cli"` で sibling の CLI を直接
参照する。repo 外で reference にするときは `gem "lilac-cli", "~> 0.1"`
に書き換えて使う。

### 構造

```
7guis/
├── lilac.config.rb
├── Gemfile
├── components/
│   └── gallery-nav.lil    # 全ページ共通の上部ナビ (1 つだけ .lil)
├── pages/
│   ├── index.html         # gallery 目次
│   ├── 01-counter.html
│   ├── 02-temperature.html
│   ├── 03-flight-booker.html
│   ├── 04-timer.html
│   └── 05-crud.html
└── public/
    ├── style.css                  # 共有スタイル (dist/ にミラー)
    ├── boot.js                    # 共有 module script で createVM + Lilac.start
    ├── lang-init.js               # <head> 同期実行で <html data-lang> を seed
    └── vendor/
        └── lilac-full/            # target=full の wasm + JS bridge
            ├── lilac-full.wasm    # (gitignore 対象、手動 sync)
            └── mruby-wasm-js/     # (同上)
```

各 task page は:
- 上部に `<div data-use="gallery-nav"></div>` で nav を差し込む
- task 固有の markup + `<script type="text/ruby">` を inline で書く
- `<script type="module" src="/boot.js">` で boot

## 関連 doc

- [`../docs/lilac-workflow.md`](../docs/lilac-workflow.md) — `lilac new` / `lilac dev` / `lilac build` 全般
- [`../docs/lilac-rails-integration.md`](../docs/lilac-rails-integration.md) — Rails と組み合わせるときのディレクトリ構成
- [`../README.md`](../README.md) — Quick start(runtime-only と同じレイヤの例)
- [`../cli/README.md`](../cli/README.md) — CLI の機能一覧
