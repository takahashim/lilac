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

## 4. 配布 (npm package テンプレート)

### 4.1 ディレクトリ構造

```
my-plugin/
├── package.json
├── index.js
├── index.d.ts
├── README.md
├── LICENSE
├── src/
│   └── plugin.rb          ← mrblib (configure source)
└── plugin.mrb              ← build artifact (ignore in git)
```

### 4.2 `package.json`

```json
{
  "name": "@myorg/lilac-plugin-foo",
  "version": "0.1.0",
  "type": "module",
  "main": "./index.js",
  "types": "./index.d.ts",
  "exports": {
    ".": {
      "types": "./index.d.ts",
      "default": "./index.js"
    },
    "./bytecode": "./plugin.mrb"
  },
  "files": ["index.js", "index.d.ts", "plugin.mrb", "README.md", "LICENSE"],
  "peerDependencies": {
    "@takahashim/lilac-compiled": "^0.1.0"
  },
  "peerDependenciesMeta": {
    "@takahashim/lilac-compiled": { "optional": true }
  }
}
```

`peerDependency` を **optional** にしておくと `lilac-full` ユーザーも
同じ package を install できる (両 variant の `boot({ plugins })` が
plug-in を受け付ける)。

### 4.3 `index.js`

```js
export const pluginBytecodeUrl = new URL("./plugin.mrb", import.meta.url);

export async function loadPlugin() {
  const res = await fetch(pluginBytecodeUrl);
  if (!res.ok) {
    throw new Error(`failed to fetch plugin.mrb (HTTP ${res.status})`);
  }
  return new Uint8Array(await res.arrayBuffer());
}
```

bundler が `URL("./xxx.mrb", import.meta.url)` を asset として扱うため、
Vite / esbuild / webpack ともそのまま動く。

### 4.4 ビルドターゲット

CI / Makefile で:

```makefile
plugin.mrb: src/plugin.rb
	bundle exec lilac plugin-build $< -o $@
```

---

## 5. ユーザーが使う (`boot({ plugins })`)

### 5.1 基本パターン

```js
import { boot } from "@takahashim/lilac-compiled";
import { loadPlugin } from "@myorg/lilac-plugin-foo";

const [appMrb, pluginMrb] = await Promise.all([
  fetch("./app.mrb").then((r) => r.arrayBuffer()).then((b) => new Uint8Array(b)),
  loadPlugin(),
]);

await boot({ bytecode: appMrb, plugins: [pluginMrb] });
```

### 5.2 複数 plug-in

```js
await boot({
  bytecode: appMrb,
  plugins: [pluginA, pluginB, pluginC],
});
```

配列の **順序が load 順序**。`register_directive` の上書き挙動を利用して
plug-in 間で directive を上書きしたい場合は順序を制御する。

### 5.3 lilac-full でも同じ

```js
import { boot } from "@takahashim/lilac-full";
// 残りは同じ
```

`lilac-full` の boot helper も `plugins` を受け付ける。

---

## 6. 制約と注意点

### 6.1 pure Ruby のみ

plug-in は **mruby source + 標準 gem の組み合わせ**で書く。C 拡張は
core wasm に linked 済みでないと使えない。例えば `mruby-yaml` のような
gem を plug-in 内部で `require` しても **wasm に含まれていない**ため
動かない。

### 6.2 mruby version lock

`.mrb` bytecode は mruby version-sensitive (`MRB_BINARY_*` magic / opcode
version)。plug-in を build した mruby と core wasm の mruby が一致して
いる必要がある。

- 推奨: plug-in package の `peerDependency` に core の major/minor を
  pin する (`"@takahashim/lilac-compiled": "^0.1.0"`)
- 不一致時の挙動: `vm.loadBytecode` が `RubyError` を raise

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

| Package | 提供物 | 種類 |
|---|---|---|
| `@takahashim/lilac-plugin-extras` | `data-tooltip` / `data-autofocus` | directive plug-in (`register_directive` を使う) |
| `@takahashim/lilac-plugin-router` | `Lilac::Router` (signal-based URL routing) | class plug-in (pre-load で class を import) |
| `@takahashim/lilac-plugin-async` | `Fetchy` HTTP client / `Lilac::Resource` / selector helpers | class plug-in |

`lilac-full` は上記すべての gem を wasm に linked しているので、
これらの plug-in を載せても **harmless だが redundant** (= 同じ class を
再定義するだけ)。`lilac-compiled` ユーザーが選んで install する形を想定。

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

1. `src/plugin.rb` に `register_directive` 呼び出しを書く (§2)
2. `lilac plugin-build` で `.mrb` を生成 (§3)
3. npm package として配布 (§4)
4. ユーザーは `boot({ plugins })` で読み込む (§5)

### 8.1 命名規約 (推奨)

| 種類 | 規約 |
|---|---|
| npm package 名 | `@<scope>/lilac-plugin-<name>` (例: `@myorg/lilac-plugin-i18n`) |
| pattern | `data-<name>` を base に。同名衝突は **後勝ち** (上書き) |
| kind | snake_case Symbol (例: `:i18n`) |

### 8.2 公式 plug-in との衝突回避

公式と同じ kind を登録すると **上書きされる**。第三者は公式と被らない
kind を選ぶか、明示的に上書きする意図を README に書くこと。

### 8.3 第三者 plug-in のテンプレート

このリポジトリの `npm/lilac-plugin-extras/` が最小テンプレートとして
参考になる:

```
npm/lilac-plugin-extras/
├── package.json       ← name, peerDependency, files, exports
├── index.js           ← URL + loadExtras()
├── index.d.ts         ← 型定義
├── README.md          ← 使い方
└── LICENSE
```

build artifact (`extras.mrb`) は `.gitignore` で除外し、CI で生成・公開。

---

## 参考

- [decisions §23 — Plug-in 機構 (runtime fallthrough)](./lilac-decisions.md)
- [decisions §24 — Plug-in 配布形態](./lilac-decisions.md)
- [directive spec](./lilac-directive-spec.md) — directive 値の文法
- 実装 SSOT:
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` —
    `register_directive` / `scan_extensions` の実装
  - `cli/lib/lilac/cli/plugin_build.rb` — `lilac plugin-build` 実装
  - `npm/lilac-compiled/index.js` / `npm/lilac-full/index.js` —
    `boot({ plugins })` hook
