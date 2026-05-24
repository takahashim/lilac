# 28. npm 配布を全廃、`lilac-full` を GitHub Pages から CDN 配信(ADR-25 完成)

決定日: 2026-05-24

## 問題

[ADR-25](./0025-pivot-plugin-distribution-to-rubygems.md) で plug-in 配布を
rubygems に pivot し、`lilac-compiled` wasm も npm から外したが、**「Mode 1
(CDN-only browser usage) 向けの CDN delivery」のために `@takahashim/lilac-full`
だけは npm に残した**。これは妥協で、Lilac の self-identity (= Ruby-native
framework、Node 文化非依存) と整合していない:

- そもそも npm に求めているのは **package management ではなく "permanent
  versioned URL + CDN"** だけ
- unpkg / jsDelivr は npm registry を front-end する CDN なので、別の経路で
  同じ機能を提供できれば npm 依存は外せる
- `npm publish` / `package.json` / `@takahashim` scope 管理 / `npm/lilac-full/`
  ディレクトリ + `node_modules` の維持コストが発生する (release flow + CI
  dependency + repo bloat)
- ADR-25 で「`lilac-compiled` は gem 経由、Lilac は Ruby-native」と整合性を
  確立したのに、`lilac-full` だけ npm に残るのは self-identity が破綻

## 決定

**npm 配布を即時全廃** し、`lilac-full` wasm + bridge + boot helper の CDN
delivery を **GitHub Pages** に移行する。pre-1.0 で実用ユーザーがいないため、
段階移行 (deprecation period) は不要、breaking change をそのまま実施。

### 配信 URL 形式

```html
<!-- 旧 (廃止) -->
<script type="module">
  import { boot } from "https://unpkg.com/@takahashim/lilac-full@0.1.0/index.js";
</script>

<!-- 新 -->
<script type="module">
  import { boot } from "https://takahashim.github.io/lilac/v0.1.0/index.js";
  await boot();
</script>
```

各 release tag (`v*`) → GitHub Actions が `lilac-full.wasm` + bridge files +
boot helper を build、`gh-pages` branch の `/v$VERSION/` と `/latest/` に
push。GitHub Pages は `.wasm` を `application/wasm` で正しく serve、CORS も
`Access-Control-Allow-Origin: *` (= cross-origin fetch 可)。

### gh-pages 配下のレイアウト

```
gh-pages branch /
├── v0.1.0/
│   ├── lilac.wasm                ← release build (-Oz + strip-debug、~322 KB brotli)
│   ├── index.js                  ← boot helper (相対 import で self-contained)
│   ├── index.d.ts
│   ├── README.md
│   ├── LICENSE
│   └── mruby-wasm-js/            ← bridge files
│       ├── index.js
│       ├── _memory.js
│       ├── wasi-preview1.js
│       └── ...
├── v0.1.1/
│   └── ...
└── latest/                       ← 最新 release の copy (= "always latest" URL)
    └── ...
```

`index.js` 内の import は **すべて相対** (`./mruby-wasm-js/index.js`) なので、
ブラウザは bundler / import map 不要で読み込める。これは npm 版 (`import from
"@takahashim/mruby-wasm-js"` の bare specifier) では不可能だったが、CDN
self-contained delivery では自然に達成できる。

## 影響

### 既存 unpkg URL は廃止

- `@takahashim/lilac-full` npm package の新規 publish 停止
- 既存 `0.1.0` などは npm registry に残るが、Lilac 公式 doc / example は
  すべて GitHub Pages URL に書き換え
- `npm deprecate @takahashim/lilac-full` で "moved to
  https://takahashim.github.io/lilac/" message を設定 (deprecate 自体は将来の
  メンテ作業)

### 削除されたもの

| 削除対象 | 説明 |
|---|---|
| `npm/lilac-full/` ディレクトリ | package.json / index.js / index.d.ts / README / LICENSE / node_modules を含む |
| `Makefile` `npm-pack` / `npm-clean` target | release artifact staging のための target |
| `.gitignore` の npm 関連 entry | `/npm/**/*.wasm` 等 |

### 追加されたもの

| 追加対象 | 説明 |
|---|---|
| `pages/lilac-full/` ディレクトリ | CDN delivery 用の source (index.js + index.d.ts + README + LICENSE)。release 時に `dist-pages/v$VERSION/` にコピーされる |
| `Makefile` `pages-pack` / `pages-clean` target | `dist-pages/v$VERSION/` への staging (wasm + 上記 source + bridge files) |
| `.github/workflows/release.yml` | `v*` tag push を trigger、`make lilac-full-release` → `make pages-pack` → `peaceiris/actions-gh-pages` で `gh-pages` branch に push |
| `.gitignore` の `/dist-pages/` entry | release staging 中間物 |

### lilac-cli ユーザーへの影響

**なし**。lilac-cli は wasm を vendor された相対 path
(`./vendor/lilac-{full,compiled}/lilac.wasm`) で参照しており、CDN URL を直接
使わない。本決定の影響対象は **Mode 1 (CDN-only browser usage)** のユーザー
のみ。

### Mode 1 ユーザーへの影響

ほぼなし (pre-1.0、unknown ≈ 0)。docs / examples の URL を新形式に書き換え。
旧 unpkg URL は npm registry に存続するため一時的には動くが、Lilac 公式は
案内しない。

## ADR-25 との関係

ADR-25 は「npm に残るのは `@takahashim/lilac-full` のみ」と明記していたが、
本決定で **この最後の npm 依存も解消**。ADR-25 §「npm に残るのは ...」節は
本決定で覆される。

ADR-25 §「`lilac-compiled` wasm は npm 配布しない」+ 本決定 = 「Lilac の
配布物は rubygems + GitHub Pages の 2 系統のみ」が確定。

## 28.4 トレードオフ

### 失うもの

- **npm registry 経由の discoverability**: `npm search lilac` で見つかる
  経路はゼロに。Lilac は Ruby framework なので問題なし (= 探す人は
  rubygems.org か github.com で探す)
- **unpkg / jsDelivr 専用 CDN の信頼性**: GitHub Pages は副次的サービス
  だが、`github.com` 全体の SLA に従う。Fastly CDN backing もあるため
  実用 latency は同等
- **dual-distribution の柔軟性**: npm + GitHub Pages を両出しする選択肢を
  自ら閉ざす。pre-1.0 + Mode 1 ユーザー unknown ≈ 0 のため許容

### 得るもの

- **Lilac の self-identity が完全 Ruby-native** (npm 依存ゼロ)
- **release flow の簡素化**: `npm publish` 不要、`package.json` メンテ不要
- **CI 依存の削減**: npm registry 障害の影響を受けない
- **repo の clean-up**: `npm/` ディレクトリ + 関連 Makefile / .gitignore が消滅
- **ADR-25 の精神を完成**: 「Lilac の配布物は rubygems + GitHub Pages の
  2 系統」が一貫した design narrative になる

### bandwidth 上の懸念

GitHub Pages の soft limit 100 GB/month。`lilac-full.wasm` ~322 KB brotli =
月 30 万 download まで OK。pre-1.0 + 想定ユーザー unknown ≈ 0 で問題に
なる規模ではない。将来 traffic が増えたら独自ドメイン + Cloudflare Pages
等への migration を検討 (= 良い問題)。

## 28.5 実装

- `pages/lilac-full/{index.js,index.d.ts,README.md,LICENSE}` 新設
  (`npm/lilac-full/` から adapt — bare import を相対 import に rewrite)
- `npm/` ディレクトリ全削除
- `Makefile`:
  - `npm-pack` / `npm-clean` target 削除
  - `pages-pack` / `pages-clean` target 追加 (`dist-pages/v$VERSION/` に
    wasm + boot helper + bridge を集約)
  - `clean` target の依存を `npm-clean` → `pages-clean` に変更
  - help コメント更新 (`make npm-pack` → `make pages-pack`)
- `.github/workflows/release.yml` 新設:
  - `v*` tag push → mruby-wasm-runtime セットアップ → `make lilac-full-release`
    → `make pages-pack` → `/latest/` mirror → `peaceiris/actions-gh-pages` で
    `gh-pages` branch に push (`keep_files: true` で過去 version 保存)
- `.gitignore`:
  - `/dist-pages/` を build outputs に追加
  - `/npm/**/*.wasm` 等の旧 entry を削除
- docs / runtime 内の npm URL 参照を GitHub Pages URL に書き換え:
  - `docs/lilac-rails-integration.md`: `@takahashim/lilac-full` npm 言及 → CDN URL
  - `cli/lib/lilac/cli/builder.rb`: comment 内の `@takahashim/lilac-full#boot`
    → `lilac-full's GitHub Pages CDN boot`
  - `cli/lib/lilac/cli/doctor.rb`: error message の `npm install
    @takahashim/lilac-compiled` → `gem "lilac-wasm-bin"` 案内
  - `cli/lib/lilac/cli/templates/README.md`: scaffold README の
    `node_modules/@takahashim/lilac-compiled` 経路 → `lilac-wasm-bin` gem
- `docs/lilac-proposals.md` の提案節は本 ADR 昇格に伴い削除

CLI tests 487 runs all green (本決定は build / CDN 配信周りのみで CLI
内部ロジックには影響なし)。

## 28.6 後続作業 (本決定スコープ外)

- **初回 `v$VERSION` tag push** で実 release workflow が動くことを確認
  (= dry run できないので tag を切ってから check)
- **GitHub Pages 設定**: repo Settings → Pages → Source を `gh-pages` branch
  に設定 (初回 deploy 前に手動で 1 回)
- **`@takahashim/lilac-full` npm の `npm deprecate`**: 既存 publish 済み
  version に "moved to https://takahashim.github.io/lilac/" message を貼る
  (= npm registry での被害を最小化、ただし optional)
- **独自ドメイン `lilac.dev`**: 採用予定なし。将来必要になれば GitHub Pages
  の CNAME 設定で透過的に切り替え可能

## 28.7 ステータス

着手 (2026-05-24)、Phase 1 (workflow + Makefile + 削除 + docs 更新) 完了。
初回 release tag (`v0.1.0` 等) を切るまで実 deploy は未検証。tag 切り前に
GitHub Pages 設定の事前準備 (Source = `gh-pages` branch) が必要。

`lilac-cli` / `lilac-wasm-bin` の release は ADR-25 の wasmtime-rb v45 release
待ちのため、本 ADR の実装は **wasmtime-rb と独立に landed 済み**。
