# Lilac plug-in 仕様 v0.1

Lilac は公式機能の一部 (data-tooltip / data-autofocus など) を **runtime
plug-in** として core から切り出して配布できる。本書は plug-in の書き方・
ビルド・配布・ロード方法を扱う。

| Section | 範囲 |
|---|---|
| 1 | 設計哲学と適用範囲 |
| 2 | Plug-in を書く (mrblib) |
| 3 | ビルド (`lilac plugin-build`) |
| 4 | 配布 (npm package テンプレート) |
| 5 | ユーザーが使う (`boot({ plugins })`) |
| 6 | 制約と注意点 |
| 7 | 公式 plug-in 一覧 |
| 8 | 第三者 plug-in の作り方 |

関連: [decisions §23](./lilac-decisions.md) (runtime fallthrough)、
[§24](./lilac-decisions.md) (配布形態)、
[directive spec](./lilac-directive-spec.md) (directive 全般)。

---

## 1. 設計哲学と適用範囲

### 1.1 runtime canonical

Lilac の §1 原則「runtime が canonical」を plug-in 領域にも適用する。
CLI (codegen) は built-in directive の precompile に専念し、plug-in は
**mrblib 1 ファイル**で完結する。CLI に手を入れる必要はない。

### 1.2 適用範囲

plug-in 機構は以下の用途を想定する:

- 公式機能の **分離配布** (`data-tooltip` を core から外して別 npm に)
- 第三者の **独自 directive** 提供 (例: `data-confetti`)
- アプリ固有の **共通 directive** (社内で再利用する `data-i18n` 等)

逆に向かない用途:

- アプリ単一の component 向け bind ロジック → 普通に Component 内に書く
- 全 component 共通の **boot hook** → `Lilac.start` 直前 / 直後の eval で
- **form** のような *Lilac の中核機能* → core gem (`mruby-lilac-form`)
  として `lilac-compiled` に linked、plug-in 化しない (§2 「form は core」)

なお router / async / extras も「大規模だが core ではない」境界例として
plug-in 配布する判断になった (decisions §24 参照)。lilac-full は引き続き
全部 linked のまま、lilac-compiled ユーザーが選んで install する形。

### 1.3 仕組み (1 段落で)

Plug-in は **mrblib コード** で、`lilac plugin-build` で mruby bytecode
(`.mrb`) に焼き、npm package に同梱する。アプリの boot 時に
`vm.loadBytecode` で **core より先に** load されると、その中の Ruby が
評価される。中身には 2 系統あり:

- **directive plug-in** (例: extras) — `Lilac::Directives::Scanner.
  register_directive(...) { block }` で Scanner に dispatch を登録 →
  各 component の `bind_template_hook` 末尾の `scan_extensions` が
  mount 時に dispatch する (runtime fallthrough、decisions §23)
- **class plug-in** (例: router / async) — 単に Ruby class を定義する
  だけ。ユーザー code が `Lilac::Router.new(...)` のように直接呼ぶ

どちらも load 経路 (`boot({ plugins })`) と build 経路
(`lilac plugin-build`) は同一。詳細は §7.1。

---

## 2. Plug-in を書く (mrblib)

### 2.1 最小例

`my_plugin.rb`:

```ruby
Lilac::Directives::Scanner.register_directive(
  pattern: /\Adata-confetti\z/,
  kind: :confetti,
) do |scanner, _name, raw_value, el, item, _descriptor|
  value = Lilac::Directives::Value.parse(raw_value)
  next if item.nil? && value.bare_ident?

  source = scanner.evaluator.bind_source(value, item)
  scanner.host.on(scanner.wrap_ref(el), "click") do
    burst_confetti!  # plug-in 内部のロジック
  end
end
```

これだけで `<button data-confetti="@trigger">` が click 時に
`burst_confetti!` を発火する directive になる。

### 2.2 `register_directive` のシグネチャ

```ruby
register_directive(
  pattern:,           # 属性名にマッチする Regexp。例: /\Adata-foo\z/
  kind:,              # Symbol。同じ kind を 2 回登録すると上書き
  captures_name: false, # true なら pattern の captures をブロック第 2 引数に
  phase: :default,      # :pre / :default / :post — built-in との順序
  &dispatch
)
```

ブロックは `(scanner, name, raw_value, el, item, descriptor)` の 6 引数。

| 引数 | 内容 |
|---|---|
| `scanner` | `Lilac::Directives::Scanner` インスタンス。`host` / `evaluator` / `wrap_ref` を経由して runtime を操作 |
| `name` | マッチした属性名 (例: `"data-confetti"`) |
| `raw_value` | 属性値の生文字列 |
| `el` | 対象 DOM 要素 (JS-side ref) |
| `item` | iteration scope の row (data-each 配下なら row、それ以外は nil) |
| `descriptor` | scan 時に積まれた descriptor (validation / metadata 用) |

### 2.3 phase の使い分け

| phase | 用途 |
|---|---|
| `:pre` | built-in directive より先に走る。data-text / data-on の wiring に影響する pre-processing (data-field のような form 集約 directive) |
| `:default` | 普通の case。built-in と同じ phase で走るが順序は不定 |
| `:post` | built-in 後に走る。focus / scroll など mount 直後の effect 系 |

`:pre` を使う plug-in は **built-in と協調する必要がある場合のみ** 使う。
data-tooltip / data-autofocus のような独立 directive は `:default` で良い。

### 2.4 captures_name (動的 directive name)

`data-on-click` のように属性名の一部を引数として使いたい場合:

```ruby
register_directive(
  pattern: /\Adata-route-(\w+)\z/,
  kind: :route,
  captures_name: true,  # ← name match を block に渡す
) do |scanner, name, raw_value, el, item, descriptor|
  route_name = name.match(/\Adata-route-(\w+)\z/)[1]
  # ...
end
```

### 2.5 利用可能な runtime API

plug-in は以下の API を **そのまま呼べる** (core 同梱で安定):

- `Lilac::Directives::Value.parse(raw_value)` — 値の文法 parsing
- `Lilac::Directives::Scanner` の public surface (host / evaluator /
  wrap_ref / 他)
- `Lilac::Component` の bind / on / etc. (`scanner.host.bind`,
  `scanner.host.on`)
- mruby 標準ライブラリ (`mruby-string-ext` 等の core gem)

C 拡張に依存する API は plug-in からは **使えない** (§6.1)。

---

## 3. ビルド (`lilac plugin-build`)

### 3.1 基本

```sh
lilac plugin-build my_plugin.rb -o my_plugin.mrb
```

`.rb` ファイルを mruby bytecode (`.mrb`) に焼く。`Lilac.start` は付加
されない (plug-in は library 扱い)。

### 3.2 複数ファイル

```sh
lilac plugin-build \
  src/setup.rb src/foo.rb src/bar.rb \
  -o my_plugin.mrb
```

複数の `.rb` を順番に **結合** してから 1 つの `.mrb` を生成する
(mruby の gem build と同じ規約)。順序は指定した通りで、`register_*` の
呼び出し順を制御できる。

### 3.3 内部実装

`lilac plugin-build` は `lilac build` と同じ mrbc backend chain を使う:

1. `--mrbc-path` で指定された mrbc binary
2. `ENV["MRBC"]` の mrbc binary
3. `ENV["MRUBY_WASM_RUNTIME_PATH"]/mruby/build/host/bin/mrbc`
4. `lilac-wasm-bin` gem 同梱の `mrbc-host.wasm` (wasmtime-rb 駆動)
5. `$PATH` 上の `mrbc`

つまり `gem install lilac-cli && bundle install` だけで plug-in build が
完結する (外部 binary 不要)。

---

## 4. 配布 (rubygems package テンプレート)

Plug-in は **Ruby gem** として配布する。npm は経由しない (decisions §25)。
gem の中身は `mrblib/*.rb` source のみで、pre-compiled `.mrb` は含めない —
user 側の `lilac build` が手元の mrbc-host wasm で compile するため、core
wasm との mruby version 不一致が原理的に起きない。

### 4.1 ディレクトリ構造

```
my-plugin/
├── lilac-plugin-foo.gemspec
├── README.md
├── LICENSE
└── mrblib/
    ├── lilac_plugin_foo.rb       ← register_directive / class 定義
    └── lilac_plugin_foo_helper.rb
```

`mrblib/` 配下の `.rb` がアルファベット順に concat されて build される
(`PluginBuild#aggregate_sources` と同じ規約)。

### 4.2 `gemspec`

```ruby
# lilac-plugin-foo.gemspec
Gem::Specification.new do |spec|
  spec.name = "lilac-plugin-foo"
  spec.version = "0.1.0"
  spec.authors = ["..."]
  spec.summary = "..."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["mrblib/**/*.rb", "*.gemspec"]

  spec.metadata = {
    # **必須** — lilac-cli の PluginDiscovery がこの flag を見て
    # Bundler.load.specs から plug-in gem を選別する。
    "lilac_plugin"          => "true",
    "source_code_uri"       => "https://github.com/...",
    "rubygems_mfa_required" => "true",
  }
end
```

公式 plug-in 名は `lilac-plugin-<name>` 規約。第三者でも同じ規約 (§8.1)
で揃えると `gem search lilac-plugin-` で discoverable に。

### 4.3 配布手順

```sh
# 開発時
gem build lilac-plugin-foo.gemspec
# 公開
gem push lilac-plugin-foo-0.1.0.gem
```

### 4.4 CI 検証 (推奨)

plug-in mrblib が core 側 `lilac plugin-build` で問題なく compile できる
ことを CI で確認する:

```sh
# in CI
gem install lilac-cli lilac-wasm-bin
ruby -e "Gem::Specification.load('lilac-plugin-foo.gemspec').validate"
lilac plugin-build mrblib/*.rb -o /tmp/check.mrb
```

---

## 5. ユーザーが使う (Bundler auto-discovery)

### 5.1 基本パターン

```ruby
# Gemfile
source "https://rubygems.org"

gem "lilac-cli"
gem "lilac-wasm-bin"           # core wasm + bridge
gem "lilac-plugin-foo"         # ← plug-in を 1 行追加するだけ
```

```sh
bundle install
bundle exec lilac build        # auto-discovery → dist/plugins/lilac-plugin-foo.mrb
```

`lilac build` が起動時に `Bundler.load.specs` を walk し、
`metadata["lilac_plugin"] == "true"` を持つ gem を全部発見。各 gem の
`mrblib/*.rb` を `lilac plugin-build` 経由で compile、`dist/plugins/<gem-name>.mrb`
として stage、生成 boot script に loadBytecode を inject する。
`lilac.config.rb` での明示設定は不要。

### 5.2 複数 plug-in

```ruby
gem "lilac-plugin-extras"
gem "lilac-plugin-router"
gem "lilac-plugin-async"
gem "lilac-plugin-foo"         # 第三者
```

`Bundler.load.specs` は Gemfile の load order とは独立した順序を返すため、
plug-in 間の load 順序を制御したい場合は §5.4 の明示 override を使う。

### 5.3 `--target full` (= `lilac dev`) でも有効

`lilac dev` のデフォルト target (`:full`) でも plug-in は自動 stage される。
ただし `:full` は user の `<script type="module">` boot が dist HTML に
残るので、lilac-cli は `dist/lilac.plugins.json` manifest を書くだけ。
scaffold template (`lilac new` 産) の boot はその manifest を `fetch` して
loadBytecode する流れに既に対応している:

```js
// scaffold's pages/index.html (excerpt)
try {
  const res = await fetch("/lilac.plugins.json");
  if (res.ok) {
    const { plugins = [] } = await res.json();
    for (const url of plugins) {
      vm.loadBytecode(new Uint8Array(await (await fetch(url)).arrayBuffer()));
    }
  }
} catch { /* No manifest => no plug-ins; harmless. */ }
```

手書き boot を使っている場合は同等のコードを足すか scaffold パターンに
合わせる。

### 5.4 明示 override (advanced)

Bundler に乗せられない plug-in (vendored fork / pre-compiled artefact) は
`c.plugins = [...]` で直接 path を渡す:

```ruby
# lilac.config.rb
Lilac::CLI.configure do |c|
  c.plugins = [
    "vendor/my-fork/foo.mrb",
  ]
end
```

明示 override は auto-discovery と **加算的に動く** (両方 stage される)。

---

## 6. 制約と注意点

### 6.1 pure Ruby のみ

plug-in は **mruby source + 標準 gem の組み合わせ**で書く。C 拡張は
core wasm に linked 済みでないと使えない。例えば `mruby-yaml` のような
gem を plug-in 内部で `require` しても **wasm に含まれていない**ため
動かない。

### 6.2 mruby version 整合 (gem 配布で原理的に解決)

`.mrb` bytecode は mruby version-sensitive (`MRB_BINARY_*` magic / opcode
version) だが、§25 で plug-in 配布を gem-based にしたため **plug-in は
user の build 時にローカルで compile** される。同じ `lilac-wasm-bin` /
`lilac-cli` バージョンで動く mrbc が使われるので、core wasm と plug-in
.mrb の mruby version は **常に一致** する。

参考: npm 配布 (旧 §24) では事前 compile した `.mrb` を peerDependency で
pin する必要があったが、本仕様ではこの種の不一致は発生しない。

### 6.3 Boot 順序の規約

plug-in は **user code より先に** load される必要がある。`boot({ plugins })`
helper はこれを強制 (plug-in を順に loadBytecode → 最後に user bytecode)。
plug-in 自身の `register_directive` 呼び出しが user component の mount
より前に走ることが要件。

### 6.4 Build-time error は出ない

CLI は plug-in directive の存在を知らないので、template 中の
`data-confetti="@nonexistent"` のような typo は **mount 時 runtime error**
として出る (`Lilac.logger.error`)。`lilac doctor` / `lilac build` での
事前検出は不可。

これは §22 (form lint 撤回) と同じ方針 (lint は runtime で一本化)。

### 6.5 tag_hook / collect_hook は full のみ

`Lilac::Directives::Scanner.register_tag_hook` /
`register_collect_hook` は `lilac-full` の full scan path 専用。
`lilac-compiled` では発火しない。これらを使う plug-in は dev-time
validation 等の `lilac-full` 限定機能として位置付ける。

### 6.6 Stack trace

block dispatch なので backtrace に plug-in の method 名が出ない (anonymous
proc として記録)。実害は `Lilac.logger.error` の context (どの directive /
どの element) でかなり緩和される。

---

## 7. 公式 plug-in 一覧

| Gem | 提供物 | 種類 |
|---|---|---|
| `lilac-plugin-extras` | `data-tooltip` / `data-autofocus` | directive plug-in (`register_directive` を使う) |
| `lilac-plugin-router` | `Lilac::Router` (signal-based URL routing) | class plug-in (pre-load で class を import) |
| `lilac-plugin-async` | `Fetchy` HTTP client / `Lilac::Resource` / selector helpers | class plug-in |

`lilac-full` は上記すべての mruby gem を wasm に linked しているので、
これらの Ruby plug-in gem を Gemfile に書いても **harmless だが redundant**
(同じ class が二重定義される)。`lilac-compiled` ユーザーが選んで `bundle
add` する形を想定。

### 7.1 directive plug-in と class plug-in

| 種類 | 例 | 仕組み |
|---|---|---|
| **directive plug-in** | extras | `register_directive` で Scanner に登録 → `scan_extensions` が mount 時に dispatch (§1.3 参照) |
| **class plug-in** | router / async | `.mrb` を pre-load して Ruby class を定義 → user code が `Lilac::Router.new(...)` のように直接呼ぶ |

両者の境界は本質的ではなく、**「runtime に何かを provide する」** 統一形式
の上での違い。class plug-in は `register_directive` を使わない分シンプル
だが、配布・load 経路 (`boot({ plugins })`) は完全に同じ。

各 plug-in の詳細は対応する README を参照。

---

## 8. 第三者 plug-in の作り方

公式 plug-in と **まったく同じ手順**で第三者の plug-in を作れる:

1. `mrblib/<name>.rb` に `register_directive` 呼び出しまたは Ruby class
   定義を書く (§2)
2. `lilac-plugin-<name>.gemspec` に `metadata["lilac_plugin"] = "true"`
   を書く (§4)
3. gem として配布 (`gem push`) (§4.3)
4. ユーザーは Gemfile に `gem "lilac-plugin-<name>"` を 1 行追加するだけ
   (§5)

### 8.1 命名規約 (推奨)

| 種類 | 規約 |
|---|---|
| gem name | `lilac-plugin-<name>` (例: `lilac-plugin-i18n`)。`gem search lilac-plugin-` で見つけてもらえる |
| pattern | `data-<name>` を base に。同名衝突は **後勝ち** (上書き) |
| kind | snake_case Symbol (例: `:i18n`) |

### 8.2 公式 plug-in との衝突回避

公式と同じ kind を登録すると **上書きされる**。第三者は公式と被らない
kind を選ぶか、明示的に上書きする意図を README に書くこと。

### 8.3 第三者 plug-in のテンプレート

このリポジトリの `runtime/mruby-lilac-extras/` が最小テンプレートとして
参考になる:

```
runtime/mruby-lilac-extras/
├── lilac-plugin-extras.gemspec  ← name, version, metadata
├── mrbgem.rake                   ← lilac-full の wasm build に linked される
                                    (第三者 plug-in は通常不要)
└── mrblib/
    ├── lilac_extras.rb
    ├── lilac_extras_focus.rb
    └── lilac_extras_tooltip.rb
```

第三者は `mrbgem.rake` を作らなくても OK (= wasm build に linked される
ことを目指さない限り)。`.gemspec` + `mrblib/` だけで配布できる。

---

## 参考

- [decisions §23 — Plug-in 機構 (runtime fallthrough)](./lilac-decisions.md)
- [decisions §24 — Plug-in 配布形態 (npm 経由、superseded by §25)](./lilac-decisions.md)
- [decisions §25 — Plug-in を rubygems に pivot](./lilac-decisions.md)
- [directive spec](./lilac-directive-spec.md) — directive 値の文法
- 実装 SSOT:
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` —
    `register_directive` / `scan_extensions` の実装
  - `cli/lib/lilac/cli/plugin_build.rb` — `lilac plugin-build` (低レベル CLI)
  - `cli/lib/lilac/cli/plugin_discovery.rb` — Bundler walk による gem 発見
  - `cli/lib/lilac/cli/builder.rb` — discover → compile → stage → boot 注入
  - `runtime/mruby-lilac-{extras,router,async}/lilac-plugin-*.gemspec` —
    公式 plug-in の gem skeleton
