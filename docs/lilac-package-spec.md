# Lilac package 仕様 v0.2

Lilac は公式機能の一部 (data-tooltip / data-autofocus など) を **runtime
package** として core から切り出して配布できる。本書は package の書き方・
ビルド・配布・ロード方法を扱う。

| Section | 範囲 |
|---|---|
| 1 | 設計哲学と適用範囲 |
| 2 | Package を書く (mrblib、class-first Handler API) |
| 3 | ビルド (`lilac package-build`) |
| 4 | 配布 (rubygems gemspec テンプレート) |
| 5 | ユーザーが使う (Bundler auto-discovery) |
| 6 | 制約と注意点 |
| 7 | 公式 package 一覧 |
| 8 | 第三者 package の作り方 |

関連: [ADR-0023](./adr/0023-plugin-mechanism-runtime-fallthrough.md) (runtime fallthrough)、
[ADR-0025](./adr/0025-pivot-plugin-distribution-to-rubygems.md) (rubygems 配布)、
[ADR-0026](./adr/0026-rename-plugin-to-package.md) (package 命名)、
[ADR-0027](./adr/0027-class-first-handler-api.md) (class-first Handler API)、
[directive spec](./lilac-directive-spec.md) (directive 全般)。

---

## 1. 設計哲学と適用範囲

### 1.1 runtime canonical

Lilac の §1 原則「runtime が canonical」を package 領域にも適用する。
CLI (codegen) は built-in directive の precompile に専念し、package は
**mrblib 1 ファイル**で完結する。CLI に手を入れる必要はない。

### 1.2 class-first principle (ADR-0027)

Package 著者向けの公開 API は **Ruby class** で表現する。具体的には:

- `Lilac::Directives::Handler` を継承した class を書く
- `attribute "data-..."` で対応する HTML 属性を宣言する
- `def wire(ctx)` に bind ロジックを書く
- `Lilac::Directives::Scanner.register("Lilac::Foo::BarDirective")`
  で登録する (文字列、load 順非依存)

block-based の `register_directive(...) { ... }` API は廃止された
(ADR-0027 Phase H、2026-05-24)。

### 1.3 適用範囲

package 機構は以下の用途を想定する:

- 公式機能の **分離配布** (`data-tooltip` を core から外して別 gem に)
- 第三者の **独自 directive** 提供 (例: `data-confetti`)
- アプリ固有の **共通 directive** (社内で再利用する `data-i18n` 等)

逆に向かない用途:

- アプリ単一の component 向け bind ロジック → 普通に Component 内に書く
- 全 component 共通の **boot hook** → `Lilac.start` 直前 / 直後の eval で
- **form** のような *Lilac の中核機能* → core gem (`mruby-lilac-form`)
  として `lilac-compiled` に linked、package 化しない (§7.1)

なお router / async / extras も「大規模だが core ではない」境界例として
package 配布する判断になった (ADR-0025 参照)。lilac-full は引き続き
全部 linked のまま、lilac-compiled ユーザーが選んで install する形。

### 1.4 仕組み (1 段落で)

Package は **mrblib コード**を含む Ruby gem。アプリの `lilac build` が
Bundler から auto-discover し、`lilac package-build` 経路で mruby bytecode
(`.mrb`) に焼き、`dist/packages/` に stage、生成 boot script で
`vm.loadBytecode` を **core より先に** 呼ぶ。中身には 2 系統あり:

- **directive package** (例: extras) — `Lilac::Directives::Handler` を継承した
  class を定義し、`Lilac::Directives::Scanner.register("...")` で登録 →
  各 component の `bind_template_hook` 末尾の `scan_extensions` が
  mount 時に handler.wire(ctx) を呼ぶ (runtime fallthrough、ADR-0023)
- **class package** (例: router / async) — 単に Ruby class を定義する
  だけ。ユーザー code が `Lilac::Router.new(...)` のように直接呼ぶ

どちらも配布形態 (rubygems の gem) と load 経路 (Bundler auto-discovery
→ boot script による `loadBytecode`) は同一。詳細は §7.1。

---

## 2. Package を書く (mrblib)

### 2.1 最小例

`lilac_confetti.rb`:

```ruby
module Lilac
  module Confetti
    class ConfettiDirective < Lilac::Directives::Handler
      attribute "data-confetti"

      def wire(ctx)
        ctx.on(:click) { burst_confetti! }
      end

      private

      def burst_confetti!
        # package 内部のロジック
      end
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Confetti::ConfettiDirective")
```

これだけで `<button data-confetti>` が click 時に `burst_confetti!` を
発火する directive になる。

### 2.2 `Lilac::Directives::Handler` の API

`Handler` 基底 class は以下を提供する:

| Class macro | 用途 |
|---|---|
| `attribute "data-..."` | **必須**。対応する HTML 属性を宣言する。String literal のみ (regex / prefix は package API として未公開) |
| `phase :pre` / `:default` | 任意。`:pre` は built-in directive より先に走る (form の `data-field` 相当)。既定は `:default` |

| Instance method | 用途 |
|---|---|
| `def wire(ctx)` | **必須**。mount 時に element ごとに 1 回 invoke される |

### 2.3 `wire(ctx)` の Context

`ctx` (= `Lilac::Directives::Context`) には以下が生えている:

| アクセサ | 内容 |
|---|---|
| `ctx.attribute_name` | マッチした属性名 (例: `"data-confetti"`) |
| `ctx.raw_value` | 属性値の生 String (例: `"@msg"` / `"hello"`) |
| `ctx.value` | parse 済み `Value` (`Ivar` / `BareIdent`) または raw String fallback。raw が空文字なら nil |
| `ctx.element` | 対応する `Lilac::RefElement` (= attr / data / on / set_style / ... が生えた wrapper) |
| `ctx.item` | iteration scope の row (`data-each` 配下なら row、それ以外は nil) |
| `ctx.iteration?` | `!ctx.item.nil?` の sugar |
| `ctx.descriptor` | `"<tag data-ref=\"name\">"` 形式の短い識別子 (error / warn 用) |

| Helper | 用途 |
|---|---|
| `ctx.bind_attribute(name, to: v)` | HTML 属性を bind。`v` が `Value::Ivar` / `Value::BareIdent` なら reactive、`String` なら一度だけ set |
| `ctx.on(event, &block)` | `ctx.element.on(event, &block)` の sugar。listener teardown は component unmount で自動 |
| `ctx.after_mount(&block)` | `bind_template_hook` 完了後に block を実行 (autofocus / scroll-into-view 等) |
| `ctx.advanced` | escape hatch。`ctx.advanced.scanner` / `ctx.advanced.host` / `ctx.advanced.evaluator` を返す。**unstable** — Lilac の minor version で変わる可能性あり |

### 2.4 phase の使い分け

| phase | 用途 |
|---|---|
| `:pre` | built-in directive より先に走る。`data-text` / `data-on` の wiring に影響する pre-processing (form の `data-field` のような集約 directive) |
| `:default` | 普通の case。built-in と同じ phase で走るが順序は不定 |

`:pre` を使う package は **built-in と協調する必要がある場合のみ** 使う。
data-tooltip / data-autofocus のような独立 directive は `:default` で良い。

### 2.5 reactive 値を受ける directive の典型例

`data-tooltip="@msg"` のように Signal の値を attribute に流したいケース:

```ruby
module Lilac
  module Extras
    class TooltipDirective < Lilac::Directives::Handler
      attribute "data-tooltip"

      def wire(ctx)
        v = ctx.value
        unless v.is_a?(Lilac::Directives::Value)
          raise Lilac::Error,
                "Invalid value for data-tooltip: #{ctx.raw_value.inspect} " \
                "(expected `@ivar` or bare identifier)"
        end
        ctx.bind_attribute("title", to: v)
      end
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Extras::TooltipDirective")
```

`ctx.bind_attribute(..., to: ctx.value)` だけで:
- `data-tooltip="@msg"` → `@msg` の Signal が変わるたび title 再 bind
- `data-tooltip="field_name"` → iteration 中なら `it.field_name` を bind、
  iteration scope 外なら silent-skip (built-in `data-text` と同じ)
- `data-tooltip="literal-string"` → `bind_attribute` が String 分岐に入り
  一度だけ title 設定 (上の例では `raise` で弾いている)

literal を **許す**派の directive にしたければ `unless` を外せばよい。

### 2.6 利用可能な runtime API

package は以下の API を **そのまま呼べる** (core 同梱で安定):

- `Lilac::Directives::Handler` / `Lilac::Directives::Context` (= 公式 API)
- `Lilac::Directives::Value.parse(raw_value)` — 値の文法 parsing
- `Lilac::Component` の bind / on / etc. (但し直接呼ぶより `ctx` 経由が推奨)
- mruby 標準ライブラリ (`mruby-string-ext` 等の core gem)

C 拡張に依存する API は package からは **使えない** (§6.1)。

### 2.7 escape hatch (`ctx.advanced`)

Context に未だ生えていない low-level 操作が必要な場合は
`ctx.advanced.scanner` / `ctx.advanced.host` / `ctx.advanced.evaluator`
にアクセスできる。ただしこれらは **unstable**: Lilac の minor version
update で signature が変わる可能性がある。

通常は escape hatch を使う前に「Context に生やしたい helper を提案する
issue」を立てることを推奨する。例えば form runtime (`mruby-lilac-form`)
は `ctx.advanced.scanner` を経由している (form は core gem 扱いなので
unstable API 依存を許容している)。

---

## 3. ビルド (`lilac package-build`)

### 3.1 基本

```sh
lilac package-build my_package.rb -o my_package.mrb
```

`.rb` ファイルを mruby bytecode (`.mrb`) に焼く。`Lilac.start` は付加
されない (package は library 扱い)。

### 3.2 複数ファイル

```sh
lilac package-build \
  src/setup.rb src/foo.rb src/bar.rb \
  -o my_package.mrb
```

複数の `.rb` を順番に **結合** してから 1 つの `.mrb` を生成する
(mruby の gem build と同じ規約)。順序は指定した通りで、`Scanner.register`
の呼び出し順を制御できる (が、`register` は class 名を String で受け取り
late-resolve するので、ほとんどのケースで順序は気にしなくてよい)。

### 3.3 内部実装

`lilac package-build` は `lilac build` と同じ mrbc backend chain を使う:

1. `--mrbc-path` で指定された mrbc binary
2. `ENV["MRBC"]` の mrbc binary
3. `ENV["MRUBY_WASM_RUNTIME_PATH"]/mruby/build/host/bin/mrbc`
4. `lilac-wasm-bin` gem 同梱の `mrbc-host.wasm` (wasmtime-rb 駆動)
5. `$PATH` 上の `mrbc`

つまり `gem install lilac-cli && bundle install` だけで package build が
完結する (外部 binary 不要)。

---

## 4. 配布 (rubygems gemspec テンプレート)

Package は **Ruby gem** として配布する。npm は経由しない (ADR-0025)。
gem の中身は `mrblib/*.rb` source のみで、pre-compiled `.mrb` は含めない —
user 側の `lilac build` が手元の mrbc-host wasm で compile するため、core
wasm との mruby version 不一致が原理的に起きない。

### 4.1 ディレクトリ構造

```
my-package/
├── lilac-foo.gemspec
├── README.md
├── LICENSE
└── mrblib/
    ├── lilac_foo.rb              ← Handler class + Scanner.register
    └── lilac_foo_helper.rb
```

`mrblib/` 配下の `.rb` がアルファベット順に concat されて build される
(`PackageBuild#aggregate_sources` と同じ規約)。

### 4.2 `gemspec`

```ruby
# lilac-foo.gemspec
Gem::Specification.new do |spec|
  spec.name = "lilac-foo"
  spec.version = "0.1.0"
  spec.authors = ["..."]
  spec.summary = "..."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["mrblib/**/*.rb", "*.gemspec"]

  spec.metadata = {
    # **必須** — lilac-cli の PackageDiscovery がこの flag を見て
    # Bundler.load.specs から package gem を選別する。
    "lilac_package"          => "true",
    "source_code_uri"       => "https://github.com/...",
    "rubygems_mfa_required" => "true",
  }
end
```

公式 package 名は `lilac-<name>` 規約。第三者でも同じ規約 (§8.1)
で揃えると `gem search lilac-` で discoverable に。

### 4.3 配布手順

```sh
# 開発時
gem build lilac-foo.gemspec
# 公開
gem push lilac-foo-0.1.0.gem
```

### 4.4 CI 検証 (推奨)

package mrblib が core 側 `lilac package-build` で問題なく compile できる
ことを CI で確認する:

```sh
# in CI
gem install lilac-cli lilac-wasm-bin
ruby -e "Gem::Specification.load('lilac-foo.gemspec').validate"
lilac package-build mrblib/*.rb -o /tmp/check.mrb
```

---

## 5. ユーザーが使う (Bundler auto-discovery)

### 5.1 基本パターン

```ruby
# Gemfile
source "https://rubygems.org"

gem "lilac-cli"
gem "lilac-wasm-bin"           # core wasm + bridge
gem "lilac-foo"         # ← package を 1 行追加するだけ
```

```sh
bundle install
bundle exec lilac build        # auto-discovery → dist/packages/lilac-foo.mrb
```

`lilac build` が起動時に `Bundler.load.specs` を walk し、
`metadata["lilac_package"] == "true"` を持つ gem を全部発見。各 gem の
`mrblib/*.rb` を `lilac package-build` 経由で compile、`dist/packages/<gem-name>.mrb`
として stage、生成 boot script に loadBytecode を inject する。
`lilac.config.rb` での明示設定は不要。

### 5.2 複数 package

```ruby
gem "lilac-extras"
gem "lilac-router"
gem "lilac-async"
gem "lilac-foo"         # 第三者
```

`Bundler.load.specs` は Gemfile の load order とは独立した順序を返すが、
`Scanner.register` が class 名 String で受け取り late-resolve するため、
package 間の load 順序は通常気にしなくてよい。

### 5.3 `--target full` (= `lilac dev`) でも有効

`lilac dev` のデフォルト target (`:full`) でも package は自動 stage される。
ただし `:full` は user の `<script type="module">` boot が dist HTML に
残るので、lilac-cli は `dist/lilac.packages.json` manifest を書くだけ。
scaffold template (`lilac new` 産) の boot はその manifest を `fetch` して
loadBytecode する流れに既に対応している:

```js
// scaffold's pages/index.html (excerpt)
try {
  const res = await fetch("/lilac.packages.json");
  if (res.ok) {
    const { packages = [] } = await res.json();
    for (const url of packages) {
      vm.loadBytecode(new Uint8Array(await (await fetch(url)).arrayBuffer()));
    }
  }
} catch { /* No manifest => no packages; harmless. */ }
```

手書き boot を使っている場合は同等のコードを足すか scaffold パターンに
合わせる。

### 5.4 明示 override (advanced)

Bundler に乗せられない package (vendored fork / pre-compiled artefact) は
`c.packages = [...]` で直接 path を渡す:

```ruby
# lilac.config.rb
Lilac::CLI.configure do |c|
  c.packages = [
    "vendor/my-fork/foo.mrb",
  ]
end
```

明示 override は auto-discovery と **加算的に動く** (両方 stage される)。

---

## 6. 制約と注意点

### 6.1 pure Ruby のみ

package は **mruby source + 標準 gem の組み合わせ**で書く。C 拡張は
core wasm に linked 済みでないと使えない。例えば `mruby-yaml` のような
gem を package 内部で `require` しても **wasm に含まれていない**ため
動かない。

### 6.2 mruby version 整合 (gem 配布で原理的に解決)

`.mrb` bytecode は mruby version-sensitive (`MRB_BINARY_*` magic / opcode
version) だが、ADR-0025 で package 配布を gem-based にしたため **package は
user の build 時にローカルで compile** される。同じ `lilac-wasm-bin` /
`lilac-cli` バージョンで動く mrbc が使われるので、core wasm と package
.mrb の mruby version は **常に一致** する。

参考: npm 配布 (旧 ADR-0024) では事前 compile した `.mrb` を peerDependency で
pin する必要があったが、本仕様ではこの種の不一致は発生しない。

### 6.3 Boot 順序の規約

package は **user code より先に** load される必要がある。lilac-cli の
生成 boot script (`:compiled`) / `dist/lilac.packages.json` 経由の
scaffold boot (`:full`) どちらもこの順序を強制する。Handler class の定義
と `Scanner.register("...")` 呼び出しが user component の mount より前に
評価される。

### 6.4 Build-time error は出ない

CLI は package directive の存在を知らないので、template 中の
`data-confetti="@nonexistent"` のような typo は **mount 時 runtime error**
として出る (`Lilac.logger.error`)。`lilac doctor` / `lilac build` での
事前検出は不可。

これは ADR-0022 (form lint 撤回) と同じ方針 (lint は runtime で一本化)。

### 6.5 tag_hook / collect_hook は公式 package API ではない

`Lilac::Directives::Scanner.register_tag_hook` /
`register_collect_hook` は **form の内部実装専用** (ADR-0027 §27.4)。
第三者 package が使うことは想定していない (signature が安定しない
可能性があるため、本書には API として記載しない)。

tag-level な hook が本当に必要な use case が出てきた場合は issue を
立て、Handler API の延長として class 化を検討する。

### 6.6 Stack trace

Handler class + `def wire` 形式なので、backtrace には class 名 + method
名 (`MyPackage::FooDirective#wire`) がきちんと出る。block-based 旧 API
(anonymous proc) より debug しやすい。エラー context (どの directive /
どの element) は `Lilac.logger.error` が `ctx.descriptor` 相当の情報を
付加する。

---

## 7. 公式 package 一覧

| Gem | 提供物 | 種類 |
|---|---|---|
| `lilac-extras` | `data-tooltip` / `data-autofocus` | directive package (Handler class を register) |
| `lilac-router` | `Lilac::Router` (signal-based URL routing) | class package (pre-load で class を import) |
| `lilac-async` | `Fetchy` HTTP client / `Lilac::Resource` / selector helpers | class package |

`lilac-full` は上記すべての mruby gem を wasm に linked しているので、
これらの Ruby package gem を Gemfile に書いても **harmless だが redundant**
(同じ class が二重定義される)。`lilac-compiled` ユーザーが選んで `bundle
add` する形を想定。

### 7.1 directive package と class package

| 種類 | 例 | 仕組み |
|---|---|---|
| **directive package** | extras | `Handler` 継承 class を `Scanner.register` で登録 → `scan_extensions` が mount 時に `handler.wire(ctx)` を呼ぶ (§1.4 参照) |
| **class package** | router / async | `.mrb` を pre-load して Ruby class を定義 → user code が `Lilac::Router.new(...)` のように直接呼ぶ |

両者の境界は本質的ではなく、**「runtime に何かを provide する」** 統一形式
の上での違い。class package は `Scanner.register` を使わない分シンプル
だが、配布形態 (rubygems の gem) と load 経路 (Bundler auto-discovery →
`loadBytecode`) は完全に同じ。

各 package の詳細は対応する README を参照。

---

## 8. 第三者 package の作り方

公式 package と **まったく同じ手順**で第三者の package を作れる:

1. `mrblib/<name>.rb` に `Lilac::Directives::Handler` 継承 class と
   `Scanner.register("...")` 呼び出しを書く (§2)、または Ruby class
   定義を書く (class package の場合)
2. `lilac-<name>.gemspec` に `metadata["lilac_package"] = "true"`
   を書く (§4)
3. gem として配布 (`gem push`) (§4.3)
4. ユーザーは Gemfile に `gem "lilac-<name>"` を 1 行追加するだけ
   (§5)

### 8.1 命名規約 (推奨)

| 種類 | 規約 |
|---|---|
| gem name | `lilac-<name>` (例: `lilac-i18n`)。`gem search lilac-` で見つけてもらえる |
| attribute | `data-<name>` を base に。`Handler.attribute "data-..."` で宣言 |
| class name | `Lilac::<Name>::<Thing>Directive` (例: `Lilac::I18n::TranslateDirective`)。namespace を切ると複数 directive を持つ package でも衝突しにくい |

### 8.2 公式 package との衝突回避

同じ `attribute "data-..."` を 2 つの handler が宣言すると、後者は
`Lilac.logger.error` で警告されて skip される (Scanner の duplicate
guard、`handlers_by_attribute`)。第三者は公式と被らない属性名を選ぶか、
意図的な置き換えなら公式の Scanner.register を package 起動前に
解除する手段を考えること (現状そのような unregister API はないので、
公式と被らない名前を選ぶのが事実上の唯一の解)。

### 8.3 第三者 package のテンプレート

このリポジトリの `runtime/mruby-lilac-extras/` が最小テンプレートとして
参考になる:

```
runtime/mruby-lilac-extras/
├── lilac-extras.gemspec  ← name, version, metadata
├── mrbgem.rake                   ← lilac-full の wasm build に linked される
                                    (第三者 package は通常不要)
└── mrblib/
    ├── lilac_extras.rb
    ├── lilac_extras_focus.rb     ← AutofocusDirective
    └── lilac_extras_tooltip.rb   ← TooltipDirective
```

第三者は `mrbgem.rake` を作らなくても OK (= wasm build に linked される
ことを目指さない限り)。`.gemspec` + `mrblib/` だけで配布できる。

---

## 参考

- [ADR-0023](./adr/0023-plugin-mechanism-runtime-fallthrough.md) — runtime fallthrough
- [ADR-0025](./adr/0025-pivot-plugin-distribution-to-rubygems.md) — rubygems 配布
- [ADR-0026](./adr/0026-rename-plugin-to-package.md) — package 命名
- [ADR-0027](./adr/0027-class-first-handler-api.md) — class-first Handler API
- [directive spec](./lilac-directive-spec.md) — directive 値の文法
- 実装 SSOT:
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_handler.rb` —
    `Lilac::Directives::Handler` 基底 class
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_context.rb` —
    `Lilac::Directives::Context` (= `wire(ctx)` の `ctx`)
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` —
    `Scanner.register` / `scan_extensions` の実装
  - `cli/lib/lilac/cli/package_build.rb` — `lilac package-build` (低レベル CLI)
  - `cli/lib/lilac/cli/package_discovery.rb` — Bundler walk による gem 発見
  - `cli/lib/lilac/cli/builder.rb` — discover → compile → stage → boot 注入
  - `runtime/mruby-lilac-{extras,router,async}/lilac-{extras,router,async}.gemspec` —
    公式 package の gem skeleton
