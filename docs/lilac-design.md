# Lilac 設計原則

このドキュメントは Lilac の **設計原則 (why)** と **意識的に受け入れた trade-off** を集約する。

個別の主要設計判断は **[`docs/adr/`](./adr/)** 配下に ADR (1 判断 = 1 ファイル) として記録 (粒度・更新頻度が異なるため別 doc に分離)。

---

## Part I — Positioning

## 1. Lilac は何のためのフレームワークか

### Target

> "An HTML-driven reactive frontend framework for Ruby developers who are at home
> with modern HTML and CSS, and would rather reach for Ruby than
> JavaScript when adding behavior." (README より)

明示的なターゲット:
- **Ruby 開発者**(Rails / Ruby 等の経験者)
- **HTML / CSS を普通に使える層** (modern HTML / CSS のスキルを前提にする。それを Ruby で代替するつもりはない)
- **「JS でしか書けなかった部分」を Ruby に置き換えたい層** (イベント処理、reactive な状態管理、DOM 操作 — それまで JS の領域だったところ)

Lilacは「HTML/CSS で書ける部分は HTML/CSS で書く、書けない部分のみJSではなくRubyで書く」という限定的な方針で設計されている。
「JS から脱出したい」という反 JS 目的ではない(その動機なら HTMX / Hotwire等の方が学習コストが低い場合も多い)。

明示的に target にしない:
- 「JS から脱出したい」が動機の人(HTMX / Hotwire 等が向く場合)
- 巨大 SPA を Ruby で書きたい(現実的には JS/TS の方が向く)
- Ruby を抜きにして純 JS で動かしたい
- HTML / CSS を Ruby DSL で覆って書きたい(Lilac は HTML/CSS をそのまま書かせる)

### 役割分担

```
HTML  : 構造、markup、セマンティクス
CSS   : 見た目、layout、CSS で書ける動的表現
        (hover/focus 等 state selector、transition、animation、@media/@container、:has()、view transitions、scroll-driven、CSS variables による reactive 再計算 等)
Ruby  : CSS では書けない動的挙動、ロジック
        (アプリの状態管理、イベントハンドリング、データ取得・更新、業務ロジック、複雑な計算 — 以前は JS が担っていた部分)
```

要点: CSS は modern web では **状態駆動の見た目変化** を多く扱える。
hover effect、選択状態の表示、entering/leaving animation、レスポンシブレイアウト等は Ruby なしで CSS だけで書ける。
Lilac はそれらを Rubyで代替しない方針:

- **「state を Ruby signal にしてから `data-class` で class 切替」より
  「CSS state selector (:hover / :focus / :checked / :target / :has())
  で済むなら CSS で済ます」を優先**
- **transition / animation は @keyframes と transition-property で
  書く**、Ruby で時系列制御しない(必要な時のみ Ruby)
- **responsive は @media / @container query** で書く、Ruby の signal
  に viewport サイズを持たせて class 切替する設計にしない

例: モーダルの open/close
```html
<dialog data-component="ConfirmDialog" data-attr-open="@opened">
  ...
</dialog>
<style>
  dialog { transition: opacity 200ms; opacity: 0; }
  dialog[open] { opacity: 1; }
</style>
```

→ Ruby は「`@opened` という state を持つ」だけ。
transition は CSS、`open` 属性の有無は HTML の標準 attribute、style は CSS の `[open]`state selector。
Ruby が animation の各 frame を書くわけではない。

例: hover effect
```html
<button class="btn">Click me</button>
<style>
  .btn { background: #eee; transition: background 100ms; }
  .btn:hover { background: #ddd; }
</style>
```

→ hover を Ruby signal に持たせない(`@hovered` などは作らない)。
`:hover` は CSS の領域。

#### 派生規律

この役割分担を **HTML / CSS の機能を Ruby で代替しない** という明示的規律で守る:

- HTML 要素の生成は HTML で書く(Ruby builder DSL は提供しない、[ADR-0005](./adr/0005-drop-html-helper-and-bind-list-legacy.md))
- スタイル定義は CSS で書く(CSS-in-Ruby は提供しない)
- CSS で表現可能な状態変化(hover、transition、レスポンシブ)は CSSで書く(Ruby signal に閉じ込めない)
- 静的構造は markup 直書き(Component が markup を render 関数で生成するモデルは採らない、React 流の関数 component は採らない)
- Ruby と DOM の binding のみ `data-*` directive と Ruby の Signal で繋ぐ
- 「Ruby で書く」のは: 状態管理(signal)、イベントハンドラ、データ取得、computed、effect、業務ロジック

### 動作モデル

Ruby (mruby) を WebAssembly でブラウザ実行。HTML に `data-*` directive を書いて、`<script type="text/ruby">` の中で Lilac::Component を定義する。
ビルド不要で動く(CLI は optional な最適化レイヤ)。

---

## Part II — 設計原則

## 2. 設計の原則

Lilac は HTML template と Ruby コードを書く DSL なので、設計原則は複数の軸で考える。本節では 3 つの軸を立てる:

1. **Template 層**: declarative > imperative
2. **Directive 値の層**: configuration > expression
3. **役割分担**: HTML / CSS は Ruby に取り込まない

### 2.1 Template 層: declarative > imperative

HTML template 内の DOM binding は **`data-*` directive (declarative)** をcanonical とする。
Ruby imperative API (`bind`, `bind_input`, `bind_list`,`ref.on(:click)`) は **declarative で表現できない escape hatch** の位置付け。

```html
<!-- canonical (declarative) -->
<span data-text="@count">0</span>
<button data-on-click="increment">+</button>
```

```ruby
# escape hatch (imperative)
bind refs.count, text: @count           # data-text 相当
refs.button.on(:click) { increment }    # data-on-click 相当
```

両者は同じ `bind` / `effect` / `listener` primitive に帰着する(parity保証)。
**新規コードは declarative を第一選択**、imperative は以下のケース:

- declarative directive の表現力外(per-row signal、動的 DOM 生成、外部 lib との連携)
- 既存コードの後方互換
- framework の internal 実装

各 directive と対応 imperative API:

| declarative | imperative |
|---|---|
| `data-text="@m"` | `bind ref, text: @m` |
| `data-class="{a:@x}"` | `bind ref, class: {"a"=>@x}` |
| `data-attr-X="@v"` | `bind ref, attr: {"X"=>@v}` |
| `data-css-X="@v"` | `ref.set_style("--X", val)` (effect 内) |
| `data-on-click="m"` | `ref.on(:click) { ... }` |
| `data-each="@items"` | `bind_list ref, @items, key:... do ... end` |
| `data-field="email"` | `bind_input ref, @sig` |

### 2.2 Directive 値の層: configuration > expression

`data-*` directive の **値の文法は厳格に制限**:
- `@ivar` — instance variable 参照
- `it[.field]` — iteration item の field 参照(`data-each` 内)
- method 名 — `data-on-X` の handler 指定
- 登録名 — `data-form="signup"`、`data-field="email"` 等

**任意 Ruby 式は禁止**:
```html
<!-- ❌ Lilac では書けない -->
<span data-text="@count + 1">
<span data-text="user.admin? ? 'yes' : 'no'">
<span data-class="{ active: count > 0 }">
```

これは **"Templates are configuration, not code"** 原則(directive-spec
§1.1)。declarative の中でも更に狭い configuration 領域に絞っている。

派生規律:
- 計算は Ruby 側で `computed { }` として ivar 化、template は `@ivar` を参照する
- 条件分岐は `data-show` / `data-hide` で表現、template に三項演算子を持ち込まない
- text content は `data-text`、HTML 構造は markup そのもので組む
- iteration body は inline child markup として書く(`data-each` の child)

#### configuration と declarative の関係

```
imperative (例: ref.on(:click) { complex_logic })
   │
   ▼
declarative (例: HTML、SwiftUI、JSX、Vue template)
  ─ 「何を」記述、「どうやって」は engine 任せ
  ─ 制御フロー(if/loop)や式(計算)を許す DSL もある
   │
   ▼
configuration (例: YAML、Stimulus data-action、Lilac data-*)
  ─ さらに狭い: 識別子参照のみ、式は許さない
  ─ 「データ表」に近い、Turing 完全ではない
```

Lilac は 2 層で **両方とも厳格側**:
- 上段は declarative(imperative より優先)
- 下段は configuration(expression を許さない)

#### 2.2.1 「HTML 内にロジックを書かない」徹底(差別化点)

Lilac は HTML template に **JS / Ruby のいかなる式・文も書かせない**。
これは他フレームワークと明確に異なる差別化点である。

##### 他フレームワークの許容例

```html
<!-- React (JSX) -->
<button onClick={() => setCount(count + 1)}>{count() > 0 ? "+" : "0"}</button>

<!-- Vue -->
<button @click="count++" :class="{ active: count > 0 }">{{ count }}</button>

<!-- Solid (JSX、fine-grained signals) -->
<button onClick={() => setCount(count() + 1)} class={count() > 0 ? "active" : ""}>{count()}</button>

<!-- Svelte -->
<button on:click={() => count++} class:active={count > 0}>{count}</button>

<!-- Alpine -->
<button x-on:click="count++" x-text="count > 0 ? 'pos' : 'zero'"></button>
```

→ HTML 内に式 / 関数呼び出し / 算術 / 比較 / ternary / 代入が登場する。
Solid は Lilac と同じ fine-grained signal モデルだが、JSX で式自由に
書ける。template strict と reactivity model は独立な軸。

##### Lilac の制約

```html
<!-- ❌ 全部書けない -->
<button data-on-click="@count.update(&:succ)">+</button>
<button data-class="{ active: @count.value > 0 }">+</button>
<button data-text="@count.value > 0 ? 'pos' : 'zero'">+</button>

<!-- ✅ Lilac で書ける唯一の形 -->
<button data-on-click="increment">+</button>
<button data-class="{ active: @count_positive }">+</button>
<span data-text="@count_label"></span>
```

```ruby
# ロジックは全部 Ruby 側に書く
def increment(_ev) = @count.update(&:succ)

def setup
  @count = signal(0)
  @count_positive = computed { @count.value > 0 }
  @count_label    = computed { @count.value > 0 ? "pos" : "zero" }
end
```

##### 禁止される具体パターン一覧

| 禁止 | 例 | Lilac での代替 |
|---|---|---|
| inline event handler | `<button onclick="handler()">` | `data-on-click="m"` + Ruby method |
| expression in directive value | `data-text="@a + @b"` | `@sum = computed { @a.value + @b.value }` + `data-text="@sum"` |
| ternary in template | `data-class="cond ? 'a' : 'b'"` | computed signal で結果を ivar 化 |
| method call with args | `data-text="format(@x)"` | `@formatted = computed { format(@x.value) }` |
| 比較 / boolean 演算 | `data-show="@count > 0"` | `@visible = computed { @count.value > 0 }` |
| string interpolation | `data-text='"hello #{@name}"'` | `@greeting = computed { "hello #{@name.value}" }` |
| inline JS scheme URL | `<a href="javascript:...">` | URL sanitizer で raise / 別 event handler 経由 |
| `<script>` 内のロジック以外の場所 | inline `<style onload="...">` 等 | 同上 |

すべて **「ロジックは Ruby 側、HTML は identifier 参照のみ」** に変換する。

##### この差別化のメリット

1. **HTML が pure な declarative documentation**: markup を読めば構造が分かる、ロジックは Ruby 側に集約
2. **デザイナと開発者の分業がきれい**: HTML / CSS はデザイナが触れる、Ruby は開発者が触る、責務が混ざらない
3. **XSS / injection の温床を減らす**: HTML 内に code が無いのでevaluation context が無く、攻撃面が小さい
4. **CSP (Content Security Policy) との相性が良い**: inline event handler / inline script が無いので `unsafe-inline` が要らない
5. **template の static analysis が完全可能**: HTML を parse すれば directive 名と identifier 値だけが取れる、tooling 実装が楽
6. **教育コストが極小**: HTML / CSS 知識 + Ruby 知識でよく、template独自の式言語を学ぶ必要が無い

### 2.3 役割分担: HTML / CSS は Ruby に取り込まない

これは §1 の役割分担(HTML / CSS / Ruby の分業)を **設計原則** として明示する:

- **HTML / CSS で表現できることは HTML / CSS で書く**(Ruby に持ち込まない)
- **Ruby は CSS では書けない動的挙動だけを担当**(状態管理、ロジック、イベント、データ取得)

この原則から派生する具体規律(§1 役割分担参照):

- HTML 要素の生成は HTML で書く(Ruby builder DSL は提供しない)
- スタイル定義は CSS で書く(CSS-in-Ruby は提供しない)
- CSS で表現可能な状態変化(hover、transition、レスポンシブ、状態selector など modern CSS の機能)は CSS で書く、Ruby signal で代替しない
- 静的構造は markup 直書き(React の関数 component のような markup生成モデルは採らない)
- Component の役割は **既存 HTML への動的 binding** であって、HTML を作り出すことではない

#### なぜ取り込まないか

- **HTML / CSS の表現力は近年急速に高まっている**(state selector、
  container query、view transitions、:has() 等)。Ruby に閉じ込めると
  これらの恩恵を捨てることになる
- **HTML / CSS は web 標準**で、エコシステム(エディタ、devtools、
  公式ドキュメント、stackoverflow)が桁違いに豊か。Ruby DSL で覆うと
  これを失う
- **同じ markup / style が CLI codegen / runtime / 他フレームワーク
  への移植時に portable**(Ruby DSL に閉じると外に出せない)
- **Lilac の入門コストを下げる**: HTML / CSS スキルがそのまま使える、
  新しい DSL を覚えなくてよい
- **Ruby が "JS でしか書けなかった部分の代替" に集中** することで、Lilac
  が解くべき問題の範囲が明確化(= scope creep を防げる)

### 2.4 なぜ template 層と directive 値層を厳格側にしたか

(§2.3 役割分担は独自の "なぜ取り込まないか" を持つので、ここでは
§2.1 + §2.2 の rationale を述べる)

#### Template が validate しやすい
- 任意式を許さないので「typo」「未定義参照」を build / lint で検出可能
- 値の grammar が小さいので scanner / codegen / lint 実装が単純
- runtime canonical 化(directive を runtime が解釈する)が現実的に可能

#### debugger / LSP の対象が Ruby に集約される
- 計算ロジックは全部 `computed { }` 内に書く → Ruby debugger でブレーク可
- template には単純な参照しか書かれない → "template debugging" の概念が薄い
- 「式が template の中で評価されて謎の値になる」事故が起きない

#### 教育コストが低い
- 「`data-*` の値は @ivar か method 名のいずれか」2種だけ覚える
- Ruby 式の書き方を template 文脈で学び直す必要がない
- HTML / CSS のスキルがそのまま使える(§2.3 とも整合)

#### 代償(認識している)
- 「ちょっと計算したい」場面でも Ruby 側に `computed` を切る必要があり、verbose
- 例: form の派生 computed 問題(`@email_invalid`, `@email_ok` 等の ivar 連発)
- これに対応するのが `data-field` directive のような **compound directive** 設計

---

## 3. 他フレームワーク比較

### 3.1 各 framework の paradigm vs API surface

| Framework | Paradigm | Reactivity | Template DSL | API surface | Directive 値 |
|---|---|---|---|---|---|
| **React (JSX)** | declarative | VDOM diff (component re-render) | JSX = JS 式の sugar | imperative hooks | JS 式(自由) |
| **Vue** | declarative | proxy-based reactive | template (限定的式) | composition / options | 式 OK |
| **Solid** | declarative | **fine-grained signals** | JSX = JS 式の sugar | createSignal / createEffect / createMemo | JS 式(自由) |
| **Svelte** | declarative | compile-time reactive `$:` | template + reactive script | compiler-magic | 式 OK |
| **Stimulus** | mixed | **無し**(static handler) | HTML attributes (config) | imperative controller class | identifier (config) |
| **Alpine** | declarative | proxy-based reactive | HTML attributes | minimal | 式 OK |
| **Lilac** | declarative | **fine-grained signals** | HTML attributes (config) | imperative ruby + declarative directives | identifier (config) |

要点(reactivity と template strictness の 2 軸で見る):

| | template strict (config only) | template lenient (式 OK) |
|---|---|---|
| **fine-grained signals** | **Lilac** | Solid |
| proxy-based | (該当なし) | Vue, Alpine |
| compile-time | (該当なし) | Svelte |
| VDOM | (該当なし) | React |
| なし(static) | Stimulus | (該当なし) |

Lilac は **「fine-grained signals + template strict」** の独自ポジション。
Solid と reactivity model を共有しつつ template は Stimulus 並みに厳格。

- React は paradigm declarative だが API surface は imperative(hooks)、
  template は JS 式の sugar、reactivity は VDOM diff(再 render 中心)
- Vue / Alpine は proxy ベース reactive(`.value` 不要、自動 unwrap)、
  template に式を許す
- Solid は **Lilac と同じ fine-grained signal** だが JSX で式自由
- Svelte は compile-time reactive(`$:` 構文を compiler が変換)
- Stimulus は **reactivity を持たない**(controller method で imperative
  に DOM を触る)、template は config 一択

### 3.2 Lilac と Stimulus の比較

「template strict + identifier only」の点では Lilac は Stimulus と
表面的に似ているが、**reactivity の有無** が決定的に違うので、
Stimulus の変種ではない。

#### 共通点(template / wiring layer)

- HTML が骨格、Ruby/JS が動作
- `data-*` attributes で wire(値は identifier のみ、式は許さない)
- Ruby/JS class で behavior 定義
- 「Templates are configuration, not code」の哲学を共有

#### 決定的な違い: reactivity

| | Stimulus | Lilac |
|---|---|---|
| **state model** | 手書き内部変数 + `data-*-value` で sync | `Signal` / `Computed` / `Effect` |
| **state 変化の伝播** | 利用者が `targetChanged` / `valueChanged` callback で手動 sync | signal の dependency tracking で自動再計算 |
| **list 描画** | 手動で DOM を書き換える | `data-each` + key 差分(`bind_list` 内部) |
| **派生値** | 利用者が計算してから DOM に書く | `computed { }` で宣言的、auto-recompute |
| **form 状態(error/dirty/touched)** | 手書き | `Lilac::Form` の field state(reactive) |

Stimulus は **「動的 DOM 操作の controller 化」** であって reactivity は
持たない。利用者は state を変えたら明示的に DOM を update する。

Lilac は **「signal を変えれば DOM が追従する」** 設計で、利用者は
state 操作だけ書けばよく DOM 更新は framework が担う。

#### 違い: form

- Stimulus は form 用の特別機構なし(generic な controller を form-specific
  に作るのは利用者責務)
- Lilac は form gem を **core 機構**として持ち、`data-field` / `data-button`
  directive で declarative に field 状態 / submit / validation を扱う

#### 違い: 言語

- Stimulus: JS / TS、Hotwire エコシステム
- Lilac: mruby on WebAssembly、Ruby エコシステム

#### まとめ

Lilac = **「Stimulus 風 template strict」 + 「Solid 風 fine-grained signals」
+ 「Ruby + 専用 form 機構」** の組合せ。"Stimulus の Ruby 版" ではなく、
template 規律を Stimulus から借りつつ reactivity モデルは Solid 系。

### 3.3 同じ問題を各 framework でどう書くか

**お題**: ユーザがテキストを入力すると、その大文字版が下に表示される。

**React**:
```jsx
function Upper() {
  const [text, setText] = useState("");
  return (
    <>
      <input value={text} onChange={e => setText(e.target.value)} />
      <p>{text.toUpperCase()}</p>
    </>
  );
}
// 使用側(親 component の JSX 内)
<Upper />
```

**Vue (Composition)**:
```vue
<!-- Upper.vue -->
<script setup>
import { ref, computed } from 'vue'
const text = ref("")
const upper = computed(() => text.value.toUpperCase())
</script>
<template>
  <input v-model="text">
  <p>{{ upper }}</p>
</template>

<!-- 使用側(親 SFC の template 内) -->
<Upper />
```

**Solid**:
```jsx
function Upper() {
  const [text, setText] = createSignal("");
  const upper = createMemo(() => text().toUpperCase());
  return (
    <>
      <input value={text()} onInput={e => setText(e.currentTarget.value)} />
      <p>{upper()}</p>
    </>
  );
}
// 使用側(親 component の JSX 内)
<Upper />
```

**Alpine**:
```html
<div x-data="{ text: '' }">
  <input x-model="text">
  <p x-text="text.toUpperCase()"></p>
</div>
```

**Lilac**:
```html
<div data-component="Upper">
  <input data-field="text" value="">
  <p data-text="@upper"></p>
</div>
<script type="text/ruby">
  class Upper < Lilac::Component
    def setup
      @upper = computed { form[:text].value.upcase }
    end
  end
</script>
```

Alpine が最も短いが、`text.toUpperCase()` という **JS 式が template に
入る**(declarative の中に code-like 要素が混入)。Solid は Lilac と
**同じ fine-grained signal モデル**で派生値を `createMemo` (Lilac の
`computed` 相当)で書くが、JSX 内で `upper()` 関数呼び出しと
`text().toUpperCase()` を直接書ける(template に code がある)。Lilac は
computed を Ruby 側に切り、template は **`@upper` 識別子参照のみ**で
純度が高い。同じ reactivity model でも template 純度の差が出る対照例。

---

## Part III — Trade-off

## 4. 意識的に受け入れた制約

Lilac の設計は「何でもできる」を目指していない。**意識的に受け入れた制約**
を明示する:

### 4.1 任意式が書けない代償の verbose さ

template に `@count + 1` のような式が書けないため、派生値は computed
として Ruby 側に置く必要がある。

```ruby
@count_plus_one = computed { @count.value + 1 }
```

```html
<span data-text="@count_plus_one"></span>
```

これを「verbose」と感じる場面があるが、template が configuration である
こと(§2.2)を維持するための明示的コスト。**compound directive**
(`data-field` 等)で頻出パターンを糊付けすることで、verbose さを
カテゴリ毎に救う。

### 4.2 runtime / CLI の二経路維持

runtime canonical 化後も CLI codegen を残す(parity test で意味的等価を
担保)。

- pros: `.lil` プロジェクトのゼロ性能リグレッション、build-time lint の存在意義
- cons: 同じ意味を 2 経路で実装する保守負担

「CLI は optimization、runtime は spec」と位置付けることで、両者の存在
意義を分離。詳細は [ADR-0001](./adr/0001-runtime-canonical.md)。

### 4.3 imperative API の存続

declarative directive で表現できない escape hatch として imperative bind /
bind_input / bind_list / ref.on / effect は残す。

- pros: 「declarative で表現できない場面」に対応可能、後方互換、framework
  internal 実装
- cons: 「declarative と imperative の両方ある」紛らわしさ

これは「declarative > imperative」原則を **「imperative を消す」ではなく
「imperative を使わなくても済むように declarative を充実させる」**
方向で解決する選択(§2.1)。

### 4.4 mruby の制約

- **Symbol leak**: 動的 Symbol 生成を避ける規律
  ([ADR-0004](./adr/0004-symbol-leak-and-hash-keys.md))
- **Regexp の実装が小さい**: 一部 pattern (`\xHH` 等) 未対応、char-walk で
  代替
- **メタプログラミング機能の差**: MRI と比べると `defined?` 等で挙動差
- **バンドルサイズ**: full variant の release ビルドで raw 約 1MB、
  brotli 圧縮後で約 300KB。min variant(compiler / 一部 gem を除いた最小
  構成)はさらに小さく、brotli 後で 100KB 台。JS framework(React ~50KB、
  Vue ~30KB、Solid ~10KB、Alpine ~15KB、いずれも brotli 後)よりは
  大きいが、桁違いではない

これらは mruby を選んだ時点で受け入れる前提。**「Ruby をブラウザで」の
価値が制約より大きい** という判断。「軽量 frontend」の "軽量" は
mruby/JS の比較ではなく、SPA フルスタックフレームワークとの対比で
考えている(つまり大きめだが、bundle / build / npm ecosystem を引き
連れる必要が無い "軽さ" を目指す)。

### 4.5 form を集約 layer に位置付けた帰結

§2 の初期決定では「input/textarea/select の declarative bind は form 経由が
canonical」とした(`data-value` / `data-checked` を廃止し、binding は form
の `data-field` 経由に統合)。しかしコレクション内 input / 単発 toggle /
検索ボックス等で form 強制が unergonomic になることが運用で判明し、
[ADR-0021](./adr/0021-data-bind-revival-form-as-aggregation.md) で再構成した:

```
signal — 値そのもの (Signal / Computed)
binding — signal ↔ DOM input の sync。`data-bind="@X"` で declarative
form — binding 群を集めて validation / submit / reset / base_error を提供
       する **集約 layer**(binding 自体ではない)
```

3 経路で利用者が場面に応じて選ぶ:

| 必要なもの | 書き方 |
|---|---|
| DOM 結線だけ(form features 不要) | `data-bind="@X"` |
| form の validation/submit + 値が `<input>` 内 | `f.field :X` + `<input data-field="X">` |
| form の validation/submit + 値が `<input>` の外 | `f.field :X, source: @X` |

- pros: input binding の経路が `validation/submit が要るか否か` で素直に
  選べる。「検索ボックスやトグルを form と呼ぶ違和感」が data-bind で解消
- cons: 直交する 3 層(signal / binding / form)を理解する必要が出る。
  ただし「form を学ぶより data-bind から学ぶ」段階的な学習が可能になり、
  入門コストは下がる方向

imperative `bind_input` escape hatch は依然残る(decisions §2 で「escape
hatch として残す」と決めた契約は本決定後も維持)。

---

## これまでの判断のログ

主要設計判断の詳細(判断 / 背景 / rationale / トレードオフ)と一覧は [`docs/adr/`](./adr/) を参照 (index は [`adr/README.md`](./adr/README.md))。
