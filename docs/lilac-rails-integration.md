# Lilac × Rails 統合ガイド

Lilac プロジェクトを Rails アプリと併用する際の、代表的な 2 つの構成パターンと
それぞれのディレクトリレイアウト / 運用方法をまとめる。

Lilac 単体の開発フローは [`lilac-workflow.md`](./lilac-workflow.md) を参照。
本 doc は **Rails と並走させるときに何をどこに置くか** だけを扱う。

---

## 前提: どちらのパターンを選ぶか

| パターン | Rails の役割 | Lilac の役割 | 向いている用途 |
|---|---|---|---|
| **(a) SPA-style** | JSON API のみ | フロント全体(`.lil` SFC + 静的 build) | Lilac で完結する画面が大半 / API 専業の Rails を separately deploy したい |
| **(b) Islands** | HTML を返す(ERB / view 一式) | 部分的なインタラクションだけ追加 | Rails の view / 認証 / partial をそのまま活かしたい / Lilac は一部のページに島として置く |

プロジェクト単位でどちらかに寄せても、両者を混在(c)させても構わない。
判断軸:

- Rails 側で「session / CSRF / partial / Turbo」をフル活用したい → **(b)**
- フロントは全部 Lilac で書いて Rails を裏方にしたい → **(a)**
- 一部だけ SPA・残りは server-rendered → **(c) 混在**(後述)

---

## (a) Rails = JSON API、Lilac = フロント全体

**考え方**: Lilac は独立した静的サイトとして `lilac build` で `dist/` を吐く。Rails は
`/api/*` だけ返す。`dist/` を Rails の `public/` 配下に出して Rails 自体で配信するか、
別 origin (Cloudflare Pages / S3 / Netlify) にデプロイする。

### ディレクトリ構成

```
my-app/
├── Gemfile                       # rails + (group :development) lilac-cli
├── Gemfile.lock
├── app/                          # Rails: controllers, models, jobs
│   └── controllers/api/          # JSON のみ返す
├── config/
│   ├── routes.rb                 # namespace :api do ... end が中心
│   └── application.rb            # config.api_only = true でも可
├── db/
├── frontend/                     # ★ Lilac プロジェクトルート
│   ├── lilac.config.rb           # output_dir = "../public/lilac"
│   ├── components/
│   │   ├── counter.lil
│   │   └── todo-list.lil
│   ├── pages/
│   │   ├── index.html
│   │   └── todos.html
│   └── public/                   # vendor wasm 等(build 時に dist/ にコピー)
│       └── vendor/lilac-full/lilac-full.wasm
├── public/
│   └── lilac/                    # ★ `lilac build` 出力先(gitignore 推奨)
│       ├── index.html
│       ├── todos.html
│       └── vendor/lilac-full/lilac-full.wasm
└── test/ (or spec/)
```

`Gemfile` は Rails ルートで 1 本に統一する案を推奨(`bundle exec lilac` がそのまま
動くため)。`frontend/` 配下に別 Gemfile を切ると bundler の context が分かれて
オペレーションが煩雑になる。

### 設定

**`frontend/lilac.config.rb`**:

```ruby
Lilac::CLI.configure do |c|
  c.output_dir = "../public/lilac"
  c.dev_port   = 5173
end
```

**`config/routes.rb`** (Rails 側):

```ruby
Rails.application.routes.draw do
  namespace :api do
    resources :todos
  end
  # SPA fallback: HTML リクエストは全部 Lilac の index.html へ
  # (lilac-router を使う場合は hash route ではなく history mode を想定)
  get "*path", to: redirect("/lilac/index.html"),
               constraints: ->(req) { !req.xhr? && req.format.html? }
  root to: redirect("/lilac/index.html")
end
```

### 開発ワークフロー

ターミナル 2 枚で並走:

```bash
# T1: Rails (JSON API)
bin/rails s                       # http://localhost:3000

# T2: Lilac (静的フロント + SSE reload)
cd frontend
bundle exec lilac dev             # http://localhost:5173
```

ブラウザは **5173 を開く**。Lilac 側から API を叩くときは
`fetch("http://localhost:3000/api/...")`。CORS は `rack-cors` で 5173 origin を許可:

```ruby
# config/initializers/cors.rb
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "http://localhost:5173"
    resource "/api/*", headers: :any, methods: %i[get post put patch delete options]
  end
end
```

### 本番ワークフロー

```bash
cd frontend && bundle exec lilac build --target compiled
# → public/lilac/ に index.html, todos.html, bundle-<hash>.mrb, vendor/ が生成
```

`assets:precompile` や CI に組み込んで自動化する:

```ruby
# lib/tasks/lilac.rake
namespace :lilac do
  task :build do
    sh "cd frontend && bundle exec lilac build --target compiled"
  end
end

Rake::Task["assets:precompile"].enhance(["lilac:build"]) if Rake::Task.task_defined?("assets:precompile")
```

Rails で配信するなら `RAILS_SERVE_STATIC_FILES=true` か、reverse proxy(nginx)で
`/lilac/` を直接静的配信する。`.mrb` の MIME type 注意点は
[`lilac-workflow.md`](./lilac-workflow.md) のデプロイ節を参照。

### .gitignore

```
/public/lilac/
/frontend/dist/
```

### トレードオフ

- Rails view を一切使わない割り切りが必要
- 認証 cookie / session を共有する場合、API 側を cookie-based か Bearer token に統一する必要がある(SPA fallback で同一 origin なら cookie が楽)
- ページ間遷移は `mruby-lilac-router` 任せになる

---

## (b) Rails が HTML を返し、Lilac はアイランド的にインタラクションを足す

**考え方**: ERB / view がページの shell を出す。Lilac は **ランタイム canonical パス**
(`lilac-full.wasm` + `<script type="text/ruby">`)だけ使い、CLI のビルドステップは
通さない。`.lil` SFC とプレ binding codegen は使わない代わりに、Rails の partial /
helper / CSRF / Turbo がそのまま機能する。

### ディレクトリ構成

```
my-app/
├── Gemfile                       # rails のみ (lilac-cli は基本不要)
├── app/
│   ├── controllers/
│   ├── views/
│   │   ├── layouts/
│   │   │   └── application.html.erb     # ★ Lilac runtime loader を埋める
│   │   ├── shared/
│   │   │   └── _lilac_runtime.html.erb  # ★ <script type="module"> で createVM
│   │   └── todos/
│   │       ├── index.html.erb           # data-component="..." を含む普通の ERB
│   │       └── _counter.html.erb        # ★ Lilac component の partial (markup)
│   └── javascript/
│       └── lilac/
│           └── components/              # ★ コンポーネント定義 (.rb)
│               ├── counter.rb
│               └── todo_list.rb
├── config/
│   └── routes.rb                        # 普通の Rails ルーティング
├── public/
│   └── lilac/
│       └── vendor/lilac-full/
│           ├── lilac-full.wasm          # ★ 静的に配置
│           └── mruby-wasm-js/index.js   # ★ JS bridge
└── db/
```

Lilac の wasm / JS bridge は `@takahashim/lilac-full` npm package(将来) もしくは
手動コピーで `public/lilac/vendor/lilac-full/` に置く。Rails の asset pipeline
(propshaft / sprockets) に乗せる必要はない — 純 static で十分。

### Layout への組み込み

**`app/views/layouts/application.html.erb`** の末尾:

```erb
  <%= yield %>
  <%= render "shared/lilac_runtime" %>
</body>
</html>
```

**`app/views/shared/_lilac_runtime.html.erb`**:

```erb
<script type="text/ruby" id="lilac-app">
<%= Rails.root.glob("app/javascript/lilac/components/*.rb").map(&:read).join("\n").html_safe %>
Lilac.start
</script>
<script type="module">
  import { createVM } from "/lilac/vendor/lilac-full/mruby-wasm-js/index.js";
  const vm = await createVM({ wasm: "/lilac/vendor/lilac-full/lilac-full.wasm" });
  vm.evalScript("#lilac-app");
</script>
```

production では `.rb` を毎リクエスト読むのを避けるため、**起動時に 1 度 concat した
文字列を Rails.cache か定数に保持** する形にする。

### コンポーネント定義と markup

**`app/views/todos/_counter.html.erb`** (markup partial):

```erb
<div data-component="counter">
  <button data-on-click="decrement">-</button>
  <span data-text="@count">0</span>
  <button data-on-click="increment">+</button>
</div>
```

**`app/javascript/lilac/components/counter.rb`**:

```ruby
class Counter < Lilac::Component
  def setup = @count = signal(0)
  def increment(_) = @count.update { _1 + 1 }
  def decrement(_) = @count.update { _1 - 1 }
end
```

呼び出し側の view:

```erb
<h1>Todos</h1>
<%= render "counter" %>
<%= render "counter" %>   <%# 複数置いてもそれぞれ独立した state %>
```

kebab → CamelCase auto-register が効くので `Lilac.register "counter", Counter` を
書く必要はない([`lilac-spec.md`](./lilac-spec.md) 参照)。

### Turbo / Hotwire と並走する場合

Turbo の page cache / navigation が走ると Lilac の DOM binding が剥がれるため、
`turbo:load` で再 mount、`turbo:before-cache` で teardown する:

```javascript
document.addEventListener("turbo:load", () => {
  vm.evalScript("#lilac-app");   // Lilac.start を再実行する形にしておく
});
document.addEventListener("turbo:before-cache", () => {
  // 必要なら Lilac.teardown 相当
});
```

`Lilac.start` 自体が二重 mount を弾く責務を持つかどうかは
[`lilac-spec.md`](./lilac-spec.md) のライフサイクル節に準拠する。

### CSRF / form

Rails の `form_with` が出す `authenticity_token` を Lilac の
`mruby-lilac-form` から送る場合、`<meta name="csrf-token">` を読んで `Fetchy`
の default header に積む(詳細は [`lilac-form-spec.md`](./lilac-form-spec.md))。

### トレードオフ

- CLI の **lint / 事前 binding codegen の恩恵を捨てる**(directive 文法ミスは mount 時に発覚する)
- `.lil` SFC が使えない。`<template>` + Ruby を 1 ファイルにまとめたければ (a) に寄せる
- 代わりに Rails の partial / helper / 認証 / CSRF / Turbo がそのまま使える
- bundle size は `lilac-full.wasm`(brotli ~322KB)固定。`compiled` target は
  pages 全体が SSG されている前提なので island では事実上使えない

---

## (c) 混在: SPA 区画 + Rails view 区画

部分 SPA(管理画面など)+ public 側は Rails view、というケース。`/app/*` を
Lilac SPA、それ以外を Rails view に振り分ける。

```
my-app/
├── app/views/                          # 公開側 (Rails view + Lilac island)
├── frontend/                           # 管理側 SPA (Lilac)
│   ├── lilac.config.rb                 # output_dir = "../public/app"
│   ├── components/
│   └── pages/
├── public/
│   ├── app/                            # ★ SPA 出力先 (`/app/*` で配信)
│   └── lilac/vendor/lilac-full/        # ★ 共通: wasm + JS bridge
```

`config/routes.rb`:

```ruby
get "/app/*path", to: redirect("/app/index.html"),
                  constraints: ->(req) { !req.xhr? && req.format.html? }
# 残りは普通の Rails ルーティング (b パターン)
```

**`lilac-full.wasm` / JS bridge を `public/lilac/vendor/` 一箇所に集約** すれば
SPA 区画(a)と island 区画(b)で同じファイルを共有できる。SPA 側の
`lilac.config.rb` で wasm path を `/lilac/vendor/lilac-full/` に向けると無駄な
重複が消える。

---

## チェックリスト

新規プロジェクトで Lilac × Rails を始めるときの順:

1. パターン (a)/(b)/(c) を選ぶ — 上の判断軸を参照
2. (a)/(c) なら `frontend/` を `lilac new` で生成、`lilac.config.rb` の `output_dir` を `../public/...` に向ける
3. (b)/(c) なら `public/lilac/vendor/lilac-full/` に wasm + JS bridge を配置
4. Rails の `config/routes.rb` で SPA fallback / API namespace を整理
5. `.gitignore` に build 出力先(`public/lilac/`, `frontend/dist/` 等)を追加
6. (a)/(c) で本番 build を CI に組み込む(`rake lilac:build` を `assets:precompile` に enhance するなど)

---

## 関連 doc

- [`lilac-workflow.md`](./lilac-workflow.md) — Lilac 単体の dev/prod ワークフロー、target=full / compiled の使い分け
- [`lilac-spec.md`](./lilac-spec.md) — Component / Signal / lifecycle
- [`lilac-form-spec.md`](./lilac-form-spec.md) — Rails 側 partial と組み合わせるときの form ハンドリング
- [`lilac-router-spec.md`](./lilac-router-spec.md) — SPA navigation(パターン (a) で必須)
