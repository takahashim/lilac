# CDN runtime-only

GitHub Pages 上の Lilac CDN を直接読み込むサンプル。**ビルドツールも
ローカルファイルも不要** — HTML を静的ホスト(GitHub Pages, Netlify,
Cloudflare Pages, S3 等)に置けばそのまま動く。

## 使い方

```bash
# 任意の静的サーバーで配信して開く
cd examples/cdn-runtime-only
python3 -m http.server 8000
open http://127.0.0.1:8000/counter.html
```

`file://` で直接開くと CORS で wasm の取得に失敗するので、必ず HTTP で配信する。

## 仕組み

```html
<script type="text/ruby">
  class Counter < Lilac::Component
    # ... 普通の Lilac component
  end
  Lilac.register "Counter", Counter
</script>

<script type="module">
  import { boot } from "https://takahashim.github.io/lilac/v0.1.0.pre1/index.js";
  await boot();
</script>
```

`boot()` ヘルパーが以下をまとめて面倒見してくれる:

- co-located の `lilac.wasm` をロード
- `<script type="text/ruby">` を評価
- `Lilac.start` で `data-component` のマウントを起動

`createVM` を直接使う最小例(boot を経由しない場合)は
[`../runtime-only/`](../runtime-only/) を参照。

## バージョンの固定

```html
<!-- 特定バージョンに固定 (推奨) -->
import { boot } from "https://takahashim.github.io/lilac/v0.1.0.pre1/index.js";

<!-- 最新を常に追従 (破壊的変更で壊れる可能性あり) -->
import { boot } from "https://takahashim.github.io/lilac/latest/index.js";
```

公開済みバージョン一覧は
[gh-pages branch](https://github.com/takahashim/lilac/tree/gh-pages) で確認できる。

## サンプル

- [`counter.html`](./counter.html) — signal + computed を使った最小コンポーネント
