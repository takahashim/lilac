# Lilac Form 仕様

`mruby-lilac-form` gem は Lilac 上の **headless form builder** を提供する。
HTML は触らず、フィールドごとの reactive state(value / dirty / touched /
error)と submit 周りの orchestration だけを担当する。

このドキュメントは Ruby DSL の仕様と、`data-form` / `data-field` /
`data-button` directive による HTML 統合を併せて記述する。現行実装の
canonical な仕様であり、文書中の API / 挙動はすべて実装済みである。

文書は 6 つの Part に分かれる。

| Part | 範囲 | 内容 |
|---|---|---|
| I — Foundation | Sections 1-3 | 目的 / 非目標 / 基本モデル |
| II — Ruby DSL | Sections 4-8 | form / field / validator / lifecycle / button |
| III — State API | Sections 9-10 | Field 状態 / Form 状態 |
| IV — HTML 統合 | Sections 11-13 | data-form / data-field / data-button directive と CLI codegen |
| V — 典型パターン | Sections 14-16 | zero-validation 単発 input / 単一 form / multi-form |
| VI — Implementation | Sections 17-18 | 実装履歴 / 実装メモ |

---

## Part I — Foundation

## 1. 目的

- フォームの **per-field reactive state** と **集約 validity** を Lilac の Signal /
  Effect 上で提供する
- **input/textarea/select の declarative bind の中心機構** として位置付ける
  (汎用 `data-value` / `data-checked` は廃止、input binding は form 経由が
  canonical。Section 11 参照)
- HTML は利用者が書く(framework は生成しない)。`data-form` / `data-field`
  / `data-button` directive で field と button を form に紐付ける。escape
  hatch として命令的 `bind_input refs.X, @signal` も残す
- validator は **値ベース** で書ける(`validator.call(field.value)` の戻り値が
  error message)。共通 helper (`required`, `min_length` 等) をモジュール
  関数として提供
- submit 時の典型 lifecycle (touch all → validate → block call → server
  error 適用) を組み込み
- multi-submit-button や named action は `f.button :name do |values| ... end`
  で宣言、`<button data-button="name">` 経由で wire される(Section 8)

### Form gem の位置付け

`mruby-lilac-form` は **core 機能** として `mruby-lilac` の全 build variant
(`full` / `compiled`)に同梱される。理由:

- input binding が form 中心になることで、form gem は事実上必須
- `lilac-compiled` でも declarative input が動かないと validation 不可
- 「form は便利機能の1つ」ではなく「Lilac の中心 input 機構」

## 2. 非目標

- HTML / CSS の生成(Phoenix LiveView の `<.input>` のような component
  発行はしない、ただし `data-field` directive で構造慣行を支援する)
- async validator(現状 sync のみ。debounce や remote check は将来検討)
- マルチステップ wizard(必要なら component を分けて lookup/expose で
  state を共有)
- form 全体の persistence(URL / storage への serialize)。必要なら
  `persistent_signal` 等を利用者が組み合わせる

### 現時点で非対応(将来検討)

以下は現バージョンではスコープ外:

- **ネスト構造**(`user[address][street]` のような階層 field、`field_for`
  / nested form 風 DSL)
- **動的 collection**(`<%= form.fields_for :line_items %>` 相当 — 複数の
  同型サブ form を増減させる UI、配列 index で管理)
- **field array** ("tags" のような同型 field の動的追加 / 削除)

現バージョンは **flat な Symbol → Field map** のみサポート。上記が必要な
ユースケース(receipt 例の line items、kanban の cards 等)は、現状は
独自の `signal([...])` + `data-each` + 子 component の組み合わせで実現する
(form gem には依存しない)。

将来導入する際の方向性:
- ネスト: `f.nested :address do |sub| sub.field :street, ... end` 型 DSL、
  field 名は `:address__street` のような flat 化 or 真にネストした
  Field tree のどちらかを spec で詰める必要あり
- collection: `f.array :line_items do |sub| sub.field :qty, ... end` で
  「item template」を宣言、`Form#add_item(:line_items)` で動的追加。
  `data-each` と統合して `<tr data-each-field="line_items">...</tr>` 風に
  declarative 表現する形を想定
- API 後方互換: 現 flat API は将来も維持(`f.field :name` は同じ意味)、
  ネスト/collection は **追加機能** として導入

このため現 spec の `data-field="<name>"` の値 grammar は将来 ネスト path
(`address.street` 等)を扱えるよう **bare ident のみ** に絞っている
(将来 path 拡張時に `.` をセパレータとして導入する余地を残す)。

## 3. 基本モデル

```
Lilac::Component (host)
└── Lilac::Form (1 component に複数可、name で区別)
    ├── @fields:        Hash<Symbol, Field>
    ├── @base_error_signal:    Signal<String?>
    ├── @submit_attempted_signal:  Signal<Bool>
    └── @form_validator_signal:    Signal<Proc?>
        └── Lilac::Form::Field (1 field 1 instance)
            ├── @value_signal:        Signal<value>
            ├── @dirty_signal:        Signal<Bool>
            ├── @touched_signal:      Signal<Bool>
            ├── @server_error_signal: Signal<String?>
            ├── @validator_error_computed: Computed<String?>
            └── @error_signal:        Computed<String?>  ← 統合
```

Form は **host Component に紐付く Ruby オブジェクト**。Field は Form の中で
管理される。Component 内の他の Signal/Computed と同じ effect scope に
属する(component unmount で自動 dispose)。

### 3.1 Component と Form の関係(概要)

Form は **所有 component に閉じる**(component-scoped)。scanner の
ancestor walk は **自 component の subtree 内のみ** で、component 境界を
越えない。これにより:

- どの form にどの field があるか grep で完全に追える
- 子 component が親の form を勝手に書き換える事故が起きない
- 他フレームワークの component encapsulation と同じ mental model

#### 基本形(1 component 内に閉じる)

`<form>` と `<input data-field>` と Ruby の `form do |f| ... end` を
**同じ component に書く**:

```html
<div data-component="SignupForm">
  <form>
    <input data-field="email">
    <input data-field="password">
    <button type="submit">Sign up</button>
  </form>
</div>
```
```ruby
class SignupForm < Lilac::Component
  def setup
    form do |f|
      f.field :email do |field| required(field.value) end
      f.button :submit do |values| post_signup(values) end
    end
  end
end
```

- Form は SignupForm component が所有(unmount で破棄)
- 素の `<form>` なので scope 名は `:default`、Ruby も `form` (default 名)
  で参照
- `<button type="submit">` の submit は scanner が自動 wire

ほとんどのケースはこれで足りる。multi-form ページなら同じ component 内に
`form(:signup)` と `form(:signin)` を 2 つ登録すれば良い。

#### markup の再利用は HTML/CSS と server-side partial で

「label + input + error 表示」のような **markup の繰り返しを部品化したい**
ケースは、**Lilac component にしない**。共通 styling は CSS class、共通
markup は server-side partial(Rails / Phoenix etc.)に任せる:

```html
<form>
  <div class="labeled-input">
    <label>Email</label>
    <input data-field="email" type="email">
    <p class="error" data-field-error></p>
  </div>
  <div class="labeled-input">
    <label>Password</label>
    <input data-field="password" type="password">
    <p class="error" data-field-error></p>
  </div>
</form>
```

Lilac component は **状態・挙動を encapsulate するもの** であって、
markup 再利用の道具ではない。3〜5 行の HTML 重複は許容する代わりに、
mental model を単純に保つ(component = state/挙動、HTML = 構造)。

ただし「label / type / 挙動の組み合わせを設定値 (props) として受け取る
入力部品」を component 化したい場合は、**`Lilac::FieldComponent` + props**
(参照: [`lilac-props-spec.md`](./lilac-props-spec.md))の組み合わせで成立:

```html
<form>
  <div data-component="LabeledInput"
       data-prop-label="Email"
       data-prop-type="email"
       data-ref="email"></div>
  <div data-component="LabeledInput"
       data-prop-label="Password"
       data-prop-type="password"
       data-ref="password"></div>
</form>
```
```ruby
class LabeledInput < Lilac::FieldComponent
  prop :label, String
  prop :type,  String, default: "text"
  # @value は FieldComponent 基底から
end

class SignupForm < Lilac::Component
  def setup
    form do |f|
      f.field :email,    source: refs.email.component
      f.field :password, source: refs.password.component
    end
  end
end
```

#### stateful な input 部品を component 化したい場合(`Lilac::FieldComponent`)

typeahead / 日付ピッカー / リッチエディタのような **自前の internal
state を持つ入力部品** は component が正当化される。Lilac はこの用途用に
**`Lilac::FieldComponent` 基底クラス** を提供する:

```ruby
class Lilac::FieldComponent < Lilac::Component
  attr_reader :value           # public API: value signal

  def initial_value            # subclass で override 可
    ""
  end

  def setup
    @value = signal(initial_value)
  end

  def reset                    # form.reset 時に自動で呼ばれる
    @value.value = initial_value
  end
end
```

これを継承して input 部品を作り、親が `f.field :name, source: refs.X.component`
で form に組み込む(`source:` は **FieldComponent / Signal 両方を受ける
polymorphic 引数**、§5 参照):

```html
<div data-component="SignupForm">
  <form>
    <label>Country</label>
    <div data-component="CountryPicker" data-ref="country"></div>

    <label>Email</label>
    <input data-field="email" type="email">

    <button type="submit">Sign up</button>
  </form>
</div>
```
```ruby
# 子: FieldComponent を継承、value signal は基底で用意済み
class CountryPicker < Lilac::FieldComponent
  def setup
    super                      # @value = signal(initial_value) を初期化
    @options = signal([])
    @open = signal(false)
    # ... typeahead 実装(option 検索、キーボードナビ、選択処理 等)
  end
end

# 親: 子の signal を form field の backing として渡す
class SignupForm < Lilac::Component
  def setup
    form do |f|
      f.field :country, source: refs.country.component do |field|
        required(field.value)
      end
      f.field :email do |field| required(field.value) end
      f.button :submit do |values| post_signup(values) end
    end
  end
end
```

ポイント:
- **encapsulation は保たれる**: 子は form を知らない、親は子の DOM を
  知らない。`value` signal という抽象だけで橋渡し
- **two-way 自然に成立**: 親 form の `form[:country].value = "JP"` 書き込み
  は子の `@value` signal に流れ、子の UI も更新される
- **lifecycle**: Lilac は children-first mount なので parent の `setup`
  時点で `refs.country.component` は解決済み(既存仕様)
- **validator は親 form に書く**: 検証は form 全体の責務、子は値の生成と
  UI 表示のみ
- **`form.reset` で reset 自動伝播**: 親が `form.reset` を呼ぶと、`source:`
  に `FieldComponent` を渡した field について子 component の `reset` が
  呼ばれる(基底実装が `@value` を `initial_value` に戻す)
- **`source:` は polymorphic**: `FieldComponent` だけでなく生 Signal も
  受ける(後者は reset 伝播なし、§5)
- **read-only な複合値も可**: subclass が `@value = computed { ... }` で
  上書きすれば read-only field として form に渡せる(その場合 reset は
  no-op 化される、§5 参照)

`refs.X.component` は既存の Lilac API。`Lilac::FieldComponent` の詳細と
`source:` の挙動は §5。

#### scope の決まり方(早見表)

| HTML | Ruby から参照 | 所有 component |
|---|---|---|
| `<form data-form="signup">` あり | `form(:signup)` | 自 component |
| 素の `<form>`(data-form 無し)あり | `form` (= default) | 自 component |
| `<form>` 要素無し、`<input data-field>` のみ | `form` (= default) | 自 component |
| `<div data-form="X">` 等の非-form 要素 | (使用不可) | `Lilac::Error` raise |

詳細ルール:
- 素の `<form>` が同 component 内に **複数** あると `:default` が衝突して raise
  (`data-form="..."` で区別する)
- 同名 field を同 form に二重 register すると raise(typo 検出)
- HTML `<input form="...">` 属性(離れた `<form>` への association)は
  Lilac は解釈しない(warn)
- 1 component 内に **複数 form** を持つことは可能(`form(:signup)` と
  `form(:signin)` を別々に登録)
- scanner の ancestor walk は **自 component subtree 内のみ**。子
  component の subtree は walk しない(component 境界で停止)

#### 実装観点

scanner は **DOM を one-pass で走査** し、収集した directive を
**`data-field` / `data-button` 先処理 → 他 directive 後処理** の 2 段階で
wire する。これにより `<p data-text="@upper">` が `<input data-field="text">`
より前に出現する DOM 順でも、computed `form[:text].value.upcase` が正しく
動く(詳細は §18.4)。

---

## Part II — Ruby DSL

## 4. `Component#form` — 登録と参照の統一 API

`form(name = :default, &block)` は block の有無で **登録** と **参照** を
切り替える dual-purpose API。

```
form(name = :default, &block)
  block あり: name で registry に登録、Form を返す
  block なし: name で registry から Form を取り出す(無ければ auto-create)
```

### 登録(block あり)

```ruby
form do |f|                       # default 名で登録 (= :default)
  f.field :email do |field| ... end
end

form(:signup) do |f|              # 名前付きで登録
  f.field :email do |field| ... end
end
```

- 同名で再登録は **禁止**(同 component 内で `form(:foo) { ... }` を
  2 回以上呼ぶと `Lilac::Error` raise)。values をクリアしたい場合は
  `form.reset`、schema を変えたい場合は別 component / 別 form 名を使う
- 戻り値は登録した Form。ivar に保持してもよいし、参照経由でもよい

### 参照(block なし)

```ruby
form                              # default を取得(無ければ auto-create)
form(:signup)                     # :signup を取得(無ければ auto-create)
```

- **block なしの `form(name)` は常に Form を返す**(name が default でも
  named でも、無ければ空の Form を auto-create して registry に入れる)
- 対応する scope ルール: コンポーネント内に `<form data-form="signup">`
  があれば `form(:signup)`、素の `<form>`(data-form 無し)があれば
  `:default`、`<form>` 要素自体が無ければ自コンポーネントの default form
  が使われる(§11.2.1)
- これにより、`<input data-field="query">` だけ書いて Ruby は
  `form[:query].value` を読むだけ、といった最小例が成立する

### 使用例

```ruby
class SignupForm < Lilac::Component
  def setup
    form do |f|
      f.field :email, initial: "" do |field| required(field.value) end
    end

    @submit_disabled = computed { !form.valid? }

    # 通常は §8 の `f.button :submit do |values| ... end` を form 宣言
    # の中で書く。submit handler の canonical な配置場所は f.button 経由。
  end
end
```

- ivar 不要(`form` で都度 default を取れる)
- `@form = form do |f| ... end` ivar パターンも引き続き OK(同じ Form
  インスタンスが registry にも入るので両参照経路が等価)

### Registry 寿命

- component 単位(unmount で消える)
- form 自体の resource は component の DisposableSet に乗る
- 同名 form の再登録は **禁止**(`Lilac::Error` raise)。明示的 dispose
  API は不要

### `@form` ivar と Signal の関係(重要)

`@form` (Form オブジェクト) は **Signal ではない**。HTML から直接
`data-text="@form"` 等で参照しても意味を持たない。Form は中に複数の
Signal/Computed を持つ **service object** で、HTML が見るリアクティブ
値はそれら **内部の Signal** または field の状態である。

```
@form (Lilac::Form)                          ← Service object (not a Signal)
├── base_error_signal       ← Signal<String?>   (data-text バインド可)
├── submit_attempted_signal ← Signal<Bool>
└── fields[:email] (Field)
    ├── value_signal        ← Signal<value>     (bind_input の対象)
    ├── error_signal        ← Computed<String?> (data-text バインド可)
    ├── touched_signal      ← Signal<Bool>
    ├── dirty_signal        ← Signal<Bool>
    └── server_error_signal ← Signal<String?>
```

HTML から form/field 状態を見る経路は 2 通り:

1. **`data-form` / `data-field` directive** (Section 11): scanner が
   registry name で Form を引き、field name で Field を引き、内部
   Signal を自動 wire。**こちらが canonical**
2. **個別 Signal を ivar に取り出して `data-text="@ivar"` 等で bind**:
   ```ruby
   @base_error = form.base_error_signal     # 内部 Signal を ivar に
   ```
   ```html
   <p data-text="@base_error"></p>
   ```

つまり HTML と form の bridge は **registry name** (`form(:foo)` の `:foo`
と `<form data-form="foo">` の `foo`) であって、`@form` ivar 名は単なる
Ruby 側のローカル名(ivar 名は何でもよく、ivar を持たなくてもよい)。

## 5. `f.field` DSL

### `f.field` の基本構文

```ruby
f.field :email do |field|             # ref:/initial: は省略可
  required(field.value) || min_length(field.value, 4)
end

f.field :terms, type: :checkbox do |field|
  acceptance(field.value)
end

f.field :email, ref: refs.email, initial: "" do |field|   # 明示指定も可能
  required(field.value)
end
```

- `name` (必須): Symbol。field 識別子
- `ref:` (optional): 対象 DOM 要素の RefElement。省略時は **deferred binding**
  モードに入り、`data-field` directive が DOM 要素を発見した時点で scanner
  から `field.bind_to(ref)` が呼ばれて post-hoc に wire される
- `initial:` (optional): 初期値。省略時は `type` から sensible default を取る
  - `:text` / `:select` → `""`
  - `:checkbox` → `false`
- `type:` (optional, default `:text`): `:text` / `:checkbox` / `:select` のいずれか
- `source:` (optional): 外部 backing(`FieldComponent` または Signal)を指定
  (詳細は本節後半)
- block (optional): field-level validator。`(field)` または `(field, form)`を受ける

block が受け取る `field` は `Field` インスタンス。`field.value` で現在値、
`form` 引数で同一 form の他 field を参照できる。block の戻り値が nil 以外
の文字列なら error message として扱われる。

### `source:` で外部 backing を指定(+ `Lilac::FieldComponent`)

設計判断の rationale は [`lilac-decisions.md §10`](./lilac-decisions.md)。

stateful な子 component(typeahead / 日付ピッカー等)を form の field
として組み込むパターン用。`source:` は **`FieldComponent` か Signal を
受ける polymorphic 引数**:

```ruby
form do |f|
  # canonical: FieldComponent を渡す(reset 伝播あり)
  f.field :country, source: refs.country.component do |field|
    required(field.value)
  end

  # escape hatch: 生 signal を直接渡す(reset 伝播なし)
  f.field :search, source: some_external_signal
end
```

#### `source:` を渡したときの挙動

- `source:` を渡すと `initial:` は **無視**(初期値は source の現在値)
- `source:` を渡すと `ref:` も不要(子 component が自身の input を bind 済み)
- 内部 `bind_input` 呼び出しは **skip** される(double-bind 防止)
- validator / dirty / touched / server_error / show_error? / form 全体
  状態への参加は通常 field と同じ。違うのは「value signal を所有しない」
  点だけ
- 渡された値が `Lilac::FieldComponent`(または `attr_reader :value` と
  `reset` を持つ duck-typed component)の場合:
  - `value_signal` は `source.value` を直接参照
  - `form.reset` が `source.reset` を呼ぶ(§7 参照)
- 渡された値が Signal / Computed の場合:
  - `value_signal` はその Signal を直接参照
  - `form.reset` は触らない(reset 伝播なし、dev_mode で「source signal
    is not a FieldComponent, reset will not propagate」を 1 回 warn)

互換性:
- `source:` と `initial:` を **同時指定すると raise**(意味が衝突)
- `source:` と `ref:` を **同時指定しても無視**(子 component 側 bind が
  優先、dev_mode で warn)
- `initial:` ベース API と `source:` ベース API は共存

#### `Lilac::FieldComponent` 基底クラス

子 component 側で convention を守るための基底クラス:

```ruby
class Lilac::FieldComponent < Lilac::Component
  attr_reader :value

  def initial_value
    ""
  end

  def setup
    @value = signal(initial_value)
  end

  def reset
    @value.value = initial_value
  end
end
```

利用例(typeahead):

```ruby
class CountryPicker < Lilac::FieldComponent
  def setup
    super                       # @value = signal("") を初期化
    @options = signal([])
    @open = signal(false)
    # input 部品の固有実装
  end

  def initial_value
    ""                          # 必要なら override
  end
end
```

`form.reset` の挙動は §7 reset を参照。簡単に書くと:
- `value:` 経由の field の場合、field 内部 signal の reset の代わりに、
  source signal の `.respond_to?(:component)` 経由でその component の
  `reset` メソッドを呼ぶ(`FieldComponent` 基底実装が `@value` を
  `initial_value` に戻す)
- 子 component が `FieldComponent` を継承していない、または `reset`
  を持たない場合は何もしない(silent skip。`form.reset` は他の field
  の reset を続ける)

#### read-only な複合値(`@value` を `computed` にする)

DatePicker のように複数の internal signal から派生する値を field に
渡したい場合は、`@value` を `computed` で上書きする:

```ruby
class DatePicker < Lilac::FieldComponent
  def setup
    super
    @year = signal(2020)
    @month = signal(1)
    @day = signal(1)
    @value = computed { Date.new(@year.value, @month.value, @day.value) }
  end

  def reset
    @year.value = 2020
    @month.value = 1
    @day.value = 1
  end
end
```

- `@value` が `Computed` の場合、field 側は **read-only として扱う**
  (`form[:date].value = ...` のような書き込みは silent no-op、または
  dev_mode で warn)
- reset は subclass が override する責任(基底の `reset` は signal 前提
  なので、複合 signal を持つ場合は子側で書く)

### `<input value>` からの auto-register

`<input data-field="X">` が HTML にあって Ruby に `f.field :X` 宣言が
**無い場合**、scanner が field を **auto-register** する。Ruby 宣言が
完全に省略可能になる(検索ボックス、トグル等の単発 input 用)。

```html
<input data-field="query" value="">       <!-- 単発 input、Ruby 宣言不要 -->
<input type="checkbox" data-field="agree">
```

```ruby
form do |f|
  # f.field :query / :agree の宣言は不要、auto-register される
  f.button :submit do |values|
    # values[:query] / values[:agree] が使える
  end
end
```

auto-register 規約(詳細は §11.3 + [lilac-decisions.md §7](./lilac-decisions.md)):

- **type**: `<input type="checkbox">` → `:checkbox`、他はすべて `:text`
- **initial**: HTML の `value` 属性のみ参照(checkbox の `checked` 属性、
  textarea の textContent、select の selected option 等は **無視**)
- **validator**: 無し(常に valid)
- Ruby で `f.field :X` が宣言されていればそれが優先
- dev_mode で「auto-registered field :X」を 1 回 warn(typo 検出)

checkbox の `initial: true` / select で特定 option を選択した状態 /
textarea にプリセット内容 を持ちたい場合は **Ruby 明示が必要**:

```ruby
form.field :agree, type: :checkbox, initial: true
form.field :region, initial: "asia"
form.field :bio, initial: "default text"
```

### block-less な incremental 追加 API

単発 field や `form do |f| ... end` の外で field 追加したい場合のため、
**`Component#form().field(...)`** を block 無し form 参照と組み合わせて
直接呼べる:

```ruby
form.field :query                                  # default form に追加(initial:"", type::text auto)
form.field :dark_mode, type: :checkbox             # initial: false が自動
form.field :age, initial: 18                       # 明示

# 後から validator 追加もできる
form.field :email do |field|
  required(field.value)
end
```

multi-form:

```ruby
form(:signup).field :email                         # signup form に追加
form(:signup).field :password
```

block-style と等価。auto-register と組合わせると、**validation が要らない
単発 input は Ruby 宣言完全省略可能**(scanner が HTML から自動登録)。


## 6. Validator helpers (`Lilac::Form::Validators`)

`Lilac::FormBuilder` (= `Lilac::Component` に include 済み) から呼べる。
すべて値ベース。**blank 時 skip 規約**:`required` 以外の helper は
空値で nil を返すので「optional だが入力されたら length 制約」が自然に
書ける。

| helper | 戻り値が nil になる条件 |
|---|---|
| `required(v, message: "required")` | `v` が non-blank |
| `min_length(v, n, message: nil)` | `v` が blank、または `v.length >= n` |
| `max_length(v, n, message: nil)` | `v` が blank、または `v.length <= n` |
| `length_in(v, range, message: nil)` | `v` が blank、または range が cover |
| `inclusion(v, list, message: nil)` | `v` が blank、または list に含まれる |
| `acceptance(v, message: "must be accepted")` | `v` が truthy(checkbox 用) |

合成は `||` で短絡的に書く:

```ruby
f.field :password do |field|
  required(field.value) ||
    min_length(field.value, 8) ||
    max_length(field.value, 64)
end
```

## 7. form-level validate と submit lifecycle

### form-level validator

```ruby
f.validate do |form|
  if form[:password].value != form[:password_confirm].value
    { password_confirm: "passwords don't match" }
  end
end
```

- block は form を受け取り、Hash<field_name, error_message> を返す
- 各 field の `error` は **field-level → form-level → server error の順で
  最初に non-nil なものが採用** される
- 同じ form に対して再度 `validate` を呼ぶと前のが上書き

### submit (low-level API)

通常は §8 の `f.button :submit do |values| ... end` で宣言する。低レベル
API として `Form#submit` を直接呼ぶこともできる(テストや特殊用途):

```ruby
form.submit do |values|
  response = send_to_server(values)
  if response[:ok]
    form.reset
  else
    form.set_server_errors(response[:errors]) if response[:errors]
    form.set_base_error(response[:message]) if response[:message]
  end
end
```

`Form#submit { |values| ... }` の lifecycle:

1. `@submit_attempted_signal.value = true` を立てる(以後 `show_error?` が
   touched に関係なく fire するきっかけ)
2. `clear_base_error`(前回の base error を消す)
3. 全 field を `.touch` (`@touched_signal.value = true`)
4. `valid?` を判定
5. valid なら block を呼ぶ。block 引数は `values`(field name → 現在値の
   plain Hash)
6. invalid なら block を呼ばずに return

multi-submit-button 分岐は §8 の `f.button` DSL で宣言ベースに行う。
`Form#submit` のシグネチャは `submit { |values| ... }` で、`submitter`
引数は持たない(named action は `f.button` で表現する)。

block 内では submit 結果を受けて `form.reset` (成功時) や
`form.set_server_errors(...)` / `form.set_base_error(...)` を呼ぶ。

### server error

| 種類 | 何 | API |
|---|---|---|
| field-specific | 1 field に紐付くエラー(例: "email already taken") | `Field#set_server_error(msg)`, `Form#set_server_errors({email: "..."})` |
| base error | form 全体のエラー(例: ネットワーク失敗) | `Form#set_base_error(msg)` |

server error は次の `submit` で `clear_base_error` され、field の値を
変更すれば該当 field の server_error は `clear_server_error` を明示的に
呼ぶまで残る(validator error と独立)。

### submit が yield する `values` の形

`values` は **field 構造をそのまま反映した Symbol-keyed Hash**。flat
form なら浅い Hash、将来 nesting / array (§2 末尾参照) を導入したら
nested Hash + Array に拡張される。

```ruby
# flat form
values
# => { email: "foo@example.com", password: "secret", terms: true }

# 将来の nested + array (Phase X)
values
# => {
#   email: "foo@example.com",
#   address: { street: "...", city: "..." },
#   line_items: [
#     { qty: "2", unit_price: "450" },
#     { qty: "1", unit_price: "680" }
#   ]
# }
```

### HTTP serialization は form gem の責務外

form gem は **values Hash の生成まで** を担当する。HTTP body の
serialization 形式(JSON / URL-encoded / multipart 等)は固定せず、
利用者が API server の慣行に合わせて選ぶ。

典型パターン(`f.button :submit` の handler 内で書く):

```ruby
form do |f|
  f.field :title
  f.button :submit do |values|
    # JSON body (modern API)
    Fetchy.post("/api/orders",
      body: Lilac::JSON.generate(values),
      headers: { "Content-Type" => "application/json" })
  end
end

# URL-encoded (classic / Rails 互換) — handler 内で別 encode
form do |f|
  f.field :title
  f.button :submit do |values|
    body = encode_rails_params(values)  # 利用者 or 別 helper gem
    Fetchy.post("/orders",
      body: body,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" })
  end
end
```

将来必要なら `mruby-lilac-form-encoders` のような **独立 gem** で
serialization helper を提供する設計余地はあるが、core form gem には
含めない(関心の分離 + serialization の好みが server 側の慣行依存
なため)。

### reset

`Form#reset`:
- 各 field の `reset` を呼ぶ:
  - 通常 field(`initial:` ベース、内部 signal 所有)→ value を initial に
    戻す、dirty/touched を false に、server_error を nil に
  - `source:` が `FieldComponent`(または `attr_reader :value` + `reset` を
    持つ duck-typed component)の field → field が所有していない value
    signal は触らず、**source component の `reset` を呼ぶ**(基底実装が
    `@value` を `initial_value` に戻す)。dirty/touched/server_error は
    field 側の責任なので通常通り reset
  - `source:` が生 Signal の field → value signal は触らない(reset 伝播
    なし、field 宣言時点で warn 済み)。dirty/touched/server_error のみ reset
- `@submit_attempted_signal.value = false`
- `clear_base_error`

reset 伝播の判定例:

```ruby
# 親
form do |f|
  f.field :email, initial: ""                          # 通常 field → value を "" に
  f.field :country, source: refs.country.component     # FieldComponent → 伝播
  f.field :date, source: refs.date.component           # 複合値(computed)
  f.field :search, source: external_signal             # 生 signal → 伝播なし
end

form.reset
# → :email の value_signal = ""(field 所有)
# → :country: refs.country.component.reset を呼ぶ
#   (CountryPicker.reset が @value.value = "" を実行)
# → :date: refs.date.component.reset を呼ぶ
#   (DatePicker.reset が @year/@month/@day を初期化、@value computed が自然に追従)
# → :search: external_signal には触らない(field 宣言時に warn 済み)
# 全 field の dirty/touched/server_error は reset、@submit_attempted = false
```

`FieldComponent` を継承しない arbitrary な signal を渡すケース(`source:
some_signal`)で reset を意図する場合は、親側で明示的に書く:

```ruby
def setup
  form do |f|
    f.field :x, source: some_signal
    f.button :reset_form, validate: false do
      form.reset                          # field の meta だけ reset
      some_signal.value = "default"       # 親が手動で signal を reset
    end
  end
end
```

---

## 8. `f.button` DSL(named action declarations)

form のボタンによる action(submit / save_draft / delete 等)は
`f.button :name [, validate:] do |values| ... end` で宣言する。HTML 側
`<button data-button="name">` の click が対応 handler を呼ぶ。

### `f.button` の基本構文

```ruby
form do |f|
  f.field :title, initial: ""

  # :submit は特別名: form の submit イベント (Enter キー / type=submit
  # button の default click) に対応する handler
  f.button :submit do |values|
    save(values)
  end

  # 名前付き button: <button data-button="save_draft"> の click handler
  # default: validate: true (form が valid でなければ handler を呼ばずに
  # submit_attempted を立てて error 表示を出す)
  f.button :save_draft do |values|
    save_as_draft(values)
  end

  # validate: false で validation skip (delete 等 user 入力に依存しない
  # action、現在の field 値を集めて handler を即呼ぶ)
  f.button :delete, validate: false do |values|
    delete_entry(values)
  end
end
```

### HTML との接続

```html
<form data-form="default">
  <div data-field="title"><input><p class="error"></p></div>

  <!-- type=submit (data-button 無し) → :submit handler (特別名規約) -->
  <button type="submit">Save</button>

  <!-- data-button="X" → :X handler -->
  <button type="button" data-button="save_draft">Save Draft</button>
  <button type="button" data-button="delete">Delete</button>
</form>
```

### 名前規約

| 宣言 | HTML 側のトリガ |
|---|---|
| `f.button :submit do \|values\| ... end` | `<button type="submit">` (data-button 無し) の click、または form 内 input での Enter キー |
| `f.button :save_draft do \|values\| ... end` | `<button data-button="save_draft">` の click |
| `f.button :delete, validate: false do \|values\| ... end` | `<button data-button="delete">` の click(validation skip) |

`:submit` は **特別名**。form の `submit` DOM イベント(submit ボタンや
Enter キーで発火)が登録された `:submit` handler を呼ぶ。それ以外の
名前は `data-button` で明示する click handler。

### form 外の `<button type="submit">` の扱い

- scanner が ancestor `<form>` 無しで `<button type="submit">` を発見した
  場合: **dev_mode で warn**(`Lilac.logger.warn`)、何もしない
- ブラウザの default form submit(page reload)も `<form>` ancestor が無い
  ので発火しない
- form 外の任意 click は `data-on-click="method"` を使う(form 関連
  ではない UI button 用)

### validate オプション

```ruby
f.button :save,        validate: true   do |values| ... end  # default
f.button :save_draft,  validate: false  do |values| ... end
f.button :delete,      validate: false, confirm: true do |values| ... end  # 将来
```

- `validate: true` (default): `form.valid?` を確認、false なら handler を
  呼ばずに submit_attempted_signal を立てる(各 field の touched が立ち、
  show_error? が発火、error 表示が出る)
- `validate: false`: validity を問わず handler を即呼ぶ。current values を
  渡す
- 将来検討: `confirm: true` で `window.confirm` での確認 dialog 経由(spec
  scope 外、利用者は handler 内で `JS.global[:window].call(:confirm, "...")`
  を呼べばよい)

### Form 外から button を呼ぶ

テスト等のプログラム経由で button を invoke したい場合:

```ruby
form.invoke_button(:save_draft)        # validate: true なら valid? check
form.invoke_button(:delete)
```

scanner 経由(`data-button` click)と同じ lifecycle を辿る。

### Form#submit との関係

`Form#submit { |values| ... }` は引き続き提供(プログラム経由で submit
lifecycle を呼ぶ低レベル API)。`f.button :submit` の declare は
**「:submit という特別名の button handler を Form 内に登録」する**こと
であって、`Form#submit` を呼ぶこととは別概念(invoke_button(:submit) の
中で内部的に submit が呼ばれる)。

multi-submit-button 分岐は `f.button :name do ... end` の named 宣言で
行うため、`Form#submit` の signature は `submit { |values| ... }` のみ
(submitter 引数は存在しない)。

---

## Part III — State API

## 9. `Field` 状態 API

| メソッド | 返り値 | 用途 |
|---|---|---|
| `name` | Symbol | field 識別子 |
| `value` | 現在値 (plain) | 現在値の snapshot |
| `value=(v)` | nil | 値を更新 |
| `initial_value` | initial に渡された値 | reset 後の値 |
| `touched?` | Bool | blur 経験あり / submit 経験あり |
| `dirty?` | Bool | initial と異なる値になったことがある |
| `valid?` | Bool | `error.nil?` |
| `invalid?` | Bool | `!valid?` |
| `error` | String? | 現在の error message(nil なら valid) |
| `server_error` | String? | server error のみ(validator 経由でない) |
| `show_error?` | Bool | UI で error を見せて良い条件(`invalid? && (touched? || submit_attempted?)`) |
| `touch` | nil | touched_signal を強制的に true に |
| `set_server_error(msg)` | nil | server error 設定 |
| `clear_server_error` | nil | server error クリア |
| `reset` | nil | 値・dirty・touched・server_error を初期状態に |

Signal アクセサ:
- `value_signal` — 値 Signal(`bind_input` の対象)
- `dirty_signal` / `touched_signal` — Bool Signal
- `error_signal` — 統合 error Computed(`bind ref, text:` の source として使える)

すべて Component の effect scope に乗るので、`computed { field.valid? }` の
ような派生 signal も自動 cleanup される。

## 10. `Form` 状態 API

| メソッド | 返り値 | 用途 |
|---|---|---|
| `[](name)` | Field | 名前で field 取得 |
| `fields` | Hash<Symbol, Field> | 全 field |
| `values` | Hash<Symbol, value> | plain values(非 reactive) |
| `errors` | Hash<Symbol, String> | error がある field のみ |
| `valid?` | Bool | 全 field が valid |
| `invalid?` | Bool | `!valid?` |
| `submit_attempted?` | Bool | submit が一度でも呼ばれたか |
| `base_error` | String? | 現在の base error message |
| `base_error_signal` | Signal | base error の reactive source |
| `set_base_error(msg)` / `clear_base_error` | nil | base error 操作 |
| `set_server_errors(hash)` | nil | 複数 field の server error を一括設定 |
| `submit { \|values\| ... }` | nil | low-level submit lifecycle。通常は `f.button :submit` 経由を推奨(§8) |
| `button(name, validate: true) { \|values\| ... }` | nil | named action button を登録(§8)。`<button data-button="X">` で wire |
| `invoke_button(name)` | nil | プログラム経由で button handler を発火(scanner と同じ lifecycle) |
| `reset` | nil | form 全体を初期状態に |
| `validate { \|form\| ... }` | nil | form-level validator 登録 |

---

## Part IV — HTML 統合

## 11. `data-form` / `data-field` / `data-button` directive

form gem の Ruby DSL に加えて、HTML 構造から field / button を発見・wire
する directive。これにより:

- 派生 ivar の宣言が不要(container 1つに `data-field="X"` で完結)
- 汎用 `data-value` / `data-checked` は **廃止**、input binding は form 経由
  が canonical(§1 参照)
- multi-submit-button や named action は `data-button="X"` + `f.button :X`
  の対で宣言、`root.on(:submit) + case submitter` の boilerplate 不要(§8)

### 11.1 値の grammar

```
data-form     value ::= ident       # form 登録名 (Ruby の form(:name) の :name)
data-field    value ::= ident       # field 名 (f.field :name の :name)
data-button   value ::= ident       # button 名 (f.button :name の :name)
ident         ::= [a-z_][a-zA-Z0-9_]*
```

値は **bare identifier** (`@ivar` でも `it.field` でもない)。symbol 風に
読めることを優先した(spec section 3 の ref_ident と同じ規約)。

### 11.2 `data-form="<name>"` — form scope 宣言

```html
<form data-form="signup">
  <div data-field="email">...</div>
  <div data-field="password">...</div>
</form>
```

- 子孫の `data-field` がどの form を参照するか宣言
- 値は `host.form(name)` (block なし呼び出し) で引かれる
- ancestor walk は **自 component subtree 内のみ**(component 境界で停止、
  詳細は §18.4)。stateful な子 input component を form に組み込みたい
  ときは §5 の `f.field source:` 経由で `FieldComponent` / signal を受け
  渡す(§3.1 参照)
- **`data-form` を省略した素の `<form>` も scope を作る**(`:default`
  name、§11.2.1 表を参照)。`data-form` 属性が無いと scope を作らない
  わけではなく、「明示的な命名が無いだけで `:default` scope は成立」

#### 11.2.1 `<form>` 要素のみ scope を作れる(構成パターン)

設計判断の rationale は [`lilac-decisions.md §8`](./lilac-decisions.md)。

| パターン | scope | 動作 |
|---|---|---|
| `<form data-form="signup">` | `:signup` | named scope。submit 自動 wire 可 |
| `<form>` (data-form 無し) | `:default` | 暗黙 default scope。submit 自動 wire 可 |
| `<input data-field="X">` のみ(`<form>` 要素なし) | (なし) | 自コンポーネントの default form に auto-register、submit 自動 wire は無し |
| `<div data-form="X">` 等の非-form 要素 | — | **`Lilac::Error` raise**(`data-form` は `<form>` 要素にしか書けない) |

`data-form` を `<form>` 以外に書く運用は禁止。理由:

- HTML living standard の form-associated semantics(`<form>` が canonical
  な form container、native submit / validation / reset の対象)と
  ずれた scope を Lilac だけが作るのは混乱の元
- 「submit が要らない form 風 scope」が必要なら、`<form>`(data-form
  あり / 無し)で囲んで `:submit` handler を書かなければ native submit は
  発火しない(scanner は `f.button :submit` 宣言があるときだけ submit を
  wire し、preventDefault する)。ページリロードを避ける効果としても十分
- 単なる視覚的グルーピングなら scope を作らず `<input data-field>` を
  並べるだけで足りる(default form に集約される)

同一コンポーネント内に `<form>` (data-form 無し) が **複数** ある場合も
`:default` が衝突するので `Lilac::Error` raise(明示的 `data-form` で
区別を要求)。

#### 11.2.2 HTML `form=""` 属性は Lilac は解釈しない

設計判断の rationale は [`lilac-decisions.md §9`](./lilac-decisions.md)。

```html
<form id="signup-form" data-form="signup">...</form>
<!-- どこか別の場所(他コンポーネント内など)-->
<input form="signup-form" data-field="email">
```

HTML living standard では `form=""` 属性で離れた `<form>` と関連付け
できるが、**Lilac はこれを解釈しない**:

- Lilac の form scope は ancestor DOM walk のみで決定(`form=""` を
  辿らない)
- `form=""` 属性付きの `<input data-field>` を発見した場合、
  `Lilac.logger.warn` で 1 回警告:「`form=""` attribute is ignored by
  Lilac; form scope is determined by ancestor `<form>` element only」
- native `form=""` 機能(native submit への参加)は browser がそのまま
  処理する(Lilac は触らない)

理由: `form=""` を解釈すると、document の任意の場所から任意の form に
書き込めることになり、component encapsulation が崩壊する。入れ子
コンポーネントで十分対応できるケースを cross-DOM 参照で実現するのは
overkill。

### 11.3 `data-field="<name>"` — field 宣言

container element に置く。scanner が以下を wire する:

1. **form control 発見**
   - container 内で最初に出現する `<input>` / `<textarea>` / `<select>`
2. **field の lookup または auto-register**
   - 対応 form の `fields[:<name>]` を lookup
   - 既存: Ruby 宣言 (`f.field :<name>`) が優先される
   - 未宣言: HTML から **auto-register**(規約は §11.3.1 参照)
3. **bind_input**: field の `type` (`:checkbox` なら `property: :checked`、それ以外 `:value`)
4. **container class wiring** (`data-field-no-class` で suppress 可)
   - `is-invalid` (`data-field-invalid` でカスタム) を `show_error?` で toggle
   - `is-valid` (`data-field-valid` でカスタム) を `touched? && valid?` で toggle
5. **error slot 発見と bind**
   - 優先順位: `[data-field-error]` 属性付き要素 → first descendant `.error` クラス要素 → 無ければ silent
   - 発見した要素: text を `field.error_signal` に bind、`hidden` 属性を `!show_error?` で toggle

**radio group は現バージョン未サポート**(§11.4 末尾参照)。

#### 11.3.1 auto-register 規約

Ruby に `f.field :<name>` 宣言が無い場合、scanner が field を auto-register
する。scanner は DOM を **one-pass** で走査して全 directive を一旦収集し、
**data-field / data-button の処理を他より先に行う**(`<input data-field="X">`
が `<p data-text="@derived">` より後に出現しても、derived を wire する
時点では field が既に register 済みになる)。詳細は §18.4 参照。

| 情報 | 取得元 | 規約 |
|---|---|---|
| **type** | `<input type="checkbox">` → `:checkbox`、他 → `:text` | radio は無視(未サポート) |
| **initial** | **`value` 属性のみ参照** | text 系で `value=""` 無し → `""`、checkbox は常に `false`(`checked` 属性は **無視**)|
| **validator** | 無し | 常に valid |

`value` 属性以外の初期値情報源(checkbox の `checked` 属性、textarea の
textContent、select の selected option 等)は **すべて無視**。これらを
反映したい場合は Ruby 明示が必要:

```ruby
form.field :agree, type: :checkbox, initial: true     # checkbox 初期 true
form.field :region, initial: "asia"                    # select の初期選択
form.field :bio, initial: "default text"               # textarea プリセット
```

severity:
- **dev_mode**: auto-register 発火時に `Lilac.logger.warn` で 1 回
  「auto-registered field :<name> (no f.field declaration)」を出力
  (typo の早期検出のため、production では silent)
- **CLI lint**: `data-field="X"` に対応する `f.field :X` が無い場合
  build warning(error ではなく warning、auto-register で動作するため)

詳細 rationale は [`lilac-decisions.md §7`](./lilac-decisions.md)。

### 11.4 オプション属性

| 属性 | default | 意味 |
|---|---|---|
| `data-field-invalid="<class>"` | `is-invalid` | show_error 時に container に付く class |
| `data-field-valid="<class>"` | `is-valid` | touched && valid 時に container に付く class |
| `data-field-no-class` (presence) | (off) | container class wiring suppress |
| `data-field-error` (子要素 marker) | `.error` 自動発見 | error slot 明示 |

#### radio group(現バージョン未サポート)

複数の `<input type="radio" name="X">` を 1 field として扱う radio
group は **現バージョン非対応**:

- `f.field` の `type:` 一覧に `:radio` は含めない(現状 `:text` /
  `:checkbox` / `:select` のみ)
- `data-field` の container 内に複数 radio input があっても、scanner は
  最初の 1 個しか拾わない(残りは無視)
- 単一 `<input type="radio">` を checkbox 的に扱いたいなら
  `type: :checkbox` で field を宣言できるが、HTML 標準としては不自然

正式な radio group サポートは将来 phase で検討(form gem に
`type: :radio_group` + option 列を取る field 型を追加、または `f.array`
の特殊形として表現)。現バージョンでは `data-on-change` + 自前 signal
更新の **imperative pattern** で代替する:

```html
<input type="radio" name="size" value="s" data-on-change="set_size">
<input type="radio" name="size" value="m" data-on-change="set_size">
```

```ruby
@size = signal("m")
def set_size(ev) = @size.value = ev[:target][:value].to_s
```

### 11.5 `data-button="<name>"` — named action button

`<button>` element に置く。scanner が以下を wire する:

1. ancestor を **自 component subtree 内のみ** で遡って `<form>` 要素を
   発見し、target form を解決(`<form data-form="X">` → `:X`、素の
   `<form>` → `:default`、ancestor `<form>` 無し → 自コンポーネントの
   default form)
2. form の `f.button(:<name>) do |values| ... end` 宣言を lookup
   - 未宣言 → `Lilac::Error` raise(correctness)
3. button の `click` イベントで `form.invoke_button(:<name>)` を呼ぶ
4. `<button type="submit">` の `:submit` handler wire は §18.4.1 で別途
   定義(scanner が `<form>` を発見した時点で form の submit イベントに
   直接結線)

`<button type="submit">` (data-button 無し) を **ancestor `<form>` 無し**
で発見した場合: dev_mode で warn、何もしない(browser default の form
submit も `<form>` ancestor 無しでは発火しない)。

### 11.6 制約

field / control 単位:
- `data-field` の container 内に form control 0 個:
  - **runtime scanner**: field は auto-register されるが `bind_to` は行われず、
    unbound のまま残る(error slot / class wiring は container に対して張られる)
  - **CLI codegen**: build error (`no <input>, <textarea>, or <select> found`)
- form control 2 個以上 → 最初のみ採用、2個目以降は無視(警告は出さない)
- form gem の対象 control は `<input>` / `<textarea>` / `<select>` のみ
  (HTML living standard の form-associated elements のうち。`<fieldset>`
  / `<output>` / `<object>` / `<img>` (form-associated) / form-associated
  custom elements は **無視・透過扱い** で、Lilac は wire しない)
- `<button>` は `data-button` で別系統サポート(§11.5、§18.4.1)
- 同 container に `data-field` と `data-each` の共存禁止(field は 1 row、each はリスト、衝突)

宣言 / lookup:
- `data-button` で指定した名前の button が form に無い → `Lilac::Error` raise
  (build 時にも `CrossRefLinter` が **error** として検出して build を fail
  させる — §13 参照)
- `data-field` で指定した名前の field が auto-register もできない場合
  (form gem 未ロード等)→ `Lilac::Error` raise

scope 違反(§11.2.1 / §11.2.2 を参照、ここでは要点のみ):
- `data-form` を `<form>` 以外の要素に書く → `Lilac::Error` raise
- 同一コンポーネント内に素の `<form>` (data-form 無し) が複数 → `Lilac::Error` raise(`:default` 衝突)
- 同一 form への同名 field 重複 register(Ruby `f.field` 宣言と HTML auto-register が同名で衝突する等) → `Lilac::Error` raise(後発が raise)
- `<input form="...">` 属性 → `Lilac.logger.warn` で 1 回警告、属性自体は無視

gem 未ロード:
- `Lilac::Form` クラス未定義(form gem 未ロード — `full` / `compiled` どちらも同梱しているので通常は発生しない、カスタムビルド時のみ) → `Lilac.logger.warn` で1回警告して silent skip(他の directive と同じ severity policy)

### 11.7 Lilac 内部 type の意味

Lilac 内部 type(`:text` / `:checkbox` / `:select`)は **bind_input の
property 選択にしか影響しない**:

- `:checkbox` → bind_input が `property: :checked` を使う
- それ以外(`:text` / `:select`) → bind_input が `property: :value` を使う

HTML5 input type の細分(email / number / date 等)は Lilac は区別しない。
browser 側の native UI(キーボード、date picker 等)は HTML type そのまま
有効で、Lilac は touch しない。

scanner の auto-register 時の type 判定規約(checkbox のみ HTML から
detect、他は `:text`)は §11.3.1 に集約。Ruby で `type:` を明示すれば
HTML 属性より優先される(`<input type="text"> + f.field :X, type: :checkbox`
は bind_input が `:checked` を使う、ただし UI と乖離するので非推奨)。

### 11.8 廃止された旧 directive

- `data-value="@signal"` — **廃止**。input bind は `data-field` 経由が
  canonical。escape hatch として命令的 `bind_input refs.X, @signal` は
  残るが、declarative directive としては存在しない
- `data-checked="@signal"` — **廃止**。理由は data-value と同様。
  checkbox 等は form 経由(`f.field :name, type: :checkbox`)で表現

migration: 旧コードで `<input data-value="@query">` のように書いていた
場合は、`form.field :query, initial: ""` を Ruby 側に追加し、HTML を
`<input data-field="query">` に変更する。

## 12. parity(declarative vs imperative)

同じ意味を 2 経路で書けることを保証する。両者は最終的に同じ
`Effect` / `bind_input` / `bind` 呼び出しに帰着する。

### imperative (data-field なし)

```ruby
def setup
  @form = form do |f|
    f.field :email, ref: refs.email, initial: "" do |field|
      required(field.value)
    end
  end

  email = @form[:email]
  bind refs.email_field, class: {
    "is-invalid" => computed { email.show_error? },
    "is-valid"   => computed { email.touched? && email.valid? },
  }
  bind refs.email_error,
       text: email.error_signal,
       hidden: computed { !email.show_error? }
end
```

```html
<div class="field" data-ref="email_field">
  <input data-ref="email" type="email">
  <p class="error" data-ref="email_error"></p>
</div>
```

### declarative (data-field 利用)

```ruby
def setup
  form do |f|                                      # @form ivar も省略可
    f.field :email, initial: "" do |field|         # ref: 省略
      required(field.value)
    end
  end
end
```

```html
<div class="field" data-field="email">
  <input type="email">
  <p class="error"></p>
</div>
```

両者で観察される DOM 変化は同一(parity test で担保)。

## 13. CLI build との整合 (codegen + cross-ref lint)

CLI の `lilac build` でも `data-form` / `data-field` / `data-button` を
解釈し、`bind_template_hook` 内に Ruby を生成する。**ただし現行実装では
完全 parity ではない**:

- `data-form` の submit wire と `data-button` の click wire は runtime と
  同等
- `data-field` の **value binding** は codegen される
- `data-field` の container class wiring (`is-valid` / `is-invalid`) と
  error slot wiring (`[data-field-error]` / `.error`) は **runtime scanner
  canonical** で、CLI codegen は未実装

生成された Ruby が見たい場合は `lilac.config.rb` に `codegen: :off` を
指定するとランタイム scanner にフォールバック(parity test / 挙動比較用)。

CLI lint(`CrossRefLinter`)による cross-reference チェック:

| Directive | 宣言の確認先 | severity (未宣言時) | runtime での挙動 |
|---|---|---|---|
| `data-button="<name>"` | enclosing form の `f.button :<name>` | **error** (build fail) | click handler が `Lilac::Error` raise |
| `data-field="<name>"` | enclosing form の `f.field :<name>` | warning | scanner が text field を auto-register |
| `data-form="<name>"` | top-level の `form(:<name>) do ... end` | warning (`:default` は無警告) | Component#form が auto-create |

severity の境界: **runtime で `Lilac::Error` を raise する違反は build error**、
runtime が auto-register / auto-create で recover する違反は warning。
typo 検出が主目的のときは "Did you mean: ...?" の suggestion が付く
(Levenshtein 距離 ≤ 2)。

検出には `ScriptAnalyzer` が `form(...) do |f| ... end` ブロックを Prism AST で
walk し、block 引数名 (`f` / `form_builder` 等) を anchor として `f.field` /
`f.button` を収集する。動的呼び出し (`fields.each { |n| f.field n }` 等) や
helper 経由の宣言 (`helper_form(self) { |f| f.field :x }`) は静的解析の射程外で、
false-positive を避けるため lint を控える。

それ以外で build error になるのは `DirectiveCompatibility` や codegen 自身が
検出する構文 / scope / applicability 違反
(`data-form` を `<form>` 以外に置く、`data-field` 内に control が無い等)。

---

## Part V — 典型パターン

## 14. zero-validation の単発 input(auto-register 活用例)

検索ボックスやトグル等、validation が不要な単発 input は `data-field`
+ HTML 標準 attribute だけで完結する:

```html
<div data-component="Search">
  <input data-field="query" type="search" placeholder="Search…">
  <select data-field="region">
    <option value="">All</option>
    <option value="asia">Asia</option>
    <option value="americas">Americas</option>
  </select>
  <ul>
    <li data-each="@filtered" data-key="id" data-text="it.name"></li>
  </ul>
</div>
```

```ruby
class Search < Lilac::Component
  def setup
    # form 宣言を完全に省略可能。scanner が <input data-field> を見つけた
    # ときに default form を auto-create + field を auto-register する。
    # ここでは @filtered の computed が form[:query] を読むだけで OK。
    @filtered = computed do
      q = form[:query].value.downcase
      r = form[:region].value
      ITEMS.select { |it|
        (r.empty? || it["region"] == r) && it["name"].downcase.include?(q)
      end
    end
  end
end
```

- `form[:query]` / `form[:region]` は HTML から auto-register された Field
- initial 値は `value=""` から `""`(select は最初の `<option value="">` で空)
- validator 無し
- Ruby 側の field 宣言は **完全ゼロ**(`form do |f| ... end` 自体省略可)
- block-less `form` 呼び出し(`form[:query]` の `form` 部分)が空 form を
  auto-create する(§4 / §18.3)

dev_mode で「auto-registered field :query / :region」が 1 回ずつ warn 出る
(typo 検出用、production silent)。

---

## 15. 単一 form(sign-up)

```html
<form data-component="SignupForm">
  <div class="field" data-field="email">
    <label>Email</label>
    <input type="email" placeholder="you@example.com">
    <p class="error"></p>
  </div>

  <div class="field" data-field="password">
    <label>Password</label>
    <input type="password" placeholder="8+ characters">
    <p class="error"></p>
  </div>

  <div class="field" data-field="password_confirm">
    <label>Password (confirm)</label>
    <input type="password">
    <p class="error"></p>
  </div>

  <label class="checkbox" data-field="terms" data-field-no-class>
    <input type="checkbox">
    I accept the terms.
    <span class="error" data-field-error></span>
  </label>

  <p class="base-error" data-text="@base_error" data-attr-hidden="@base_error_hide"></p>

  <!-- type=submit + data-button 無し → :submit handler を呼ぶ -->
  <button type="submit" data-attr-disabled="@submit_disabled">Sign up</button>
</form>
```

```ruby
class SignupForm < Lilac::Component
  def setup
    form do |f|
      f.field :email, initial: "" do |field|
        required(field.value) || min_length(field.value, 4) ||
          (field.value.include?("@") ? nil : "must include @")
      end
      f.field :password, initial: "" do |field|
        required(field.value) || min_length(field.value, 8)
      end
      f.field :password_confirm, initial: ""
      f.field :terms, initial: false, type: :checkbox do |field|
        acceptance(field.value)
      end
      f.validate do |form|
        { password_confirm: "passwords don't match" } \
          if form[:password].value != form[:password_confirm].value
      end

      # submit handler を form 内で declare(:submit は特別名)
      f.button :submit do |values|
        send_to_server(values)
      end
    end

    @base_error      = form.base_error_signal
    @base_error_hide = computed { form.base_error.nil? }
    @submit_disabled = computed { !form.valid? }
  end

  private

  def send_to_server(values)
    # submit logic — ここで Fetchy.post(...) 等
    # 成功時:  form.reset
    # 失敗時:  form.set_server_errors(...) / form.set_base_error(...)
  end
end
```

`root.on(:submit) do |event|; event.preventDefault ...` の boilerplate は
scanner が自動 wire するので不要(`<button type="submit">` の click や
Enter キーで form の `:submit` handler が呼ばれる)。

## 16. multi-form (sign-up + sign-in)

```html
<div data-component="AuthApp">
  <form data-form="signup">
    <div class="field" data-field="email">
      <input type="email"><p class="error"></p>
    </div>
    <div class="field" data-field="password">
      <input type="password"><p class="error"></p>
    </div>
    <button type="submit" data-attr-disabled="@signup_disabled">Sign up</button>
  </form>

  <form data-form="login">
    <div class="field" data-field="email">
      <input type="email"><p class="error"></p>
    </div>
    <div class="field" data-field="password">
      <input type="password"><p class="error"></p>
    </div>
    <button type="submit" data-attr-disabled="@login_disabled">Sign in</button>
  </form>
</div>
```

```ruby
class AuthApp < Lilac::Component
  def setup
    form(:signup) do |f|
      f.field :email, initial: ""
      f.field :password, initial: ""
      f.button :submit do |values|
        sign_up(values)
      end
    end
    form(:login) do |f|
      f.field :email, initial: ""
      f.field :password, initial: ""
      f.button :submit do |values|
        sign_in(values)
      end
    end

    @signup_disabled = computed { !form(:signup).valid? }
    @login_disabled  = computed { !form(:login).valid? }
  end

  private

  def sign_up(values); end
  def sign_in(values); end
end
```

`root.on(:submit)` で `event.target.data-form` を読んで分岐する boilerplate
は不要。scanner が `<form data-form="signup">` の submit イベントを
form(:signup) の `:submit` handler に、`<form data-form="login">` の同
イベントを form(:login) の `:submit` handler に、自動で結線する。

---

## Part VI — Implementation

## 17. 実装履歴 / Phase 内訳

仕様はすべて実装済み。詳細な差分は git log を参照(本 table は要約)。

| Phase | 内容 | ステータス |
|---|---|---|
| **A** | form gem 拡張: `Component#form` の dual-purpose 化、registry、`f.field` の `ref:` / `initial:` 省略、`source:` 引数、`Lilac::FieldComponent` 基底、`Form#reset` の伝播、`f.button` / `invoke_button`、deferred binding、core 統合(全 variant 同梱) | 完了 |
| **B** | scanner / directive 実装: one-pass DOM walk + 2-phase processing、`data-form` / `data-field` / `data-button` dispatch、auto-register、`<form>` の `:submit` auto-wire、scope validation、dev_mode warning | 完了 |
| **C** | CLI codegen 対応: `template_ast.rb` の DIRECTIVE_PATTERNS 追加、`codegen.rb` の `emit_form` / `emit_field` / `emit_button`、`directive_compatibility.rb` の collision check、`CrossRefLinter` の undeclared 警告 | 完了 |
| **D** | 廃止整理 + テスト + sample: `data-value` / `data-checked` の削除、`examples/lilac-form.html` の declarative 化、parity test、関連 docs cross-ref 更新 | 完了 |

## 18. 実装メモ

### 18.1 form gem の core 統合

`mruby-lilac-form` は **core 機能** として `build_config/lilac-{full,compiled}.rb`
すべてに同梱される(独立 gem は維持、全 variant で必須)。

`mruby-lilac-directives` の scanner は依然 form gem ロード状況に依存。
全 variant で同梱されるため `Lilac.const_defined?(:Form)` チェックは
実質常に true だが、**safety net として警告 fallback は残してある**
(将来 form gem を抜く選択肢が再浮上した場合のため)。

### 18.2 deferred binding API (form gem 側)

`Field#bind_to(ref)`:

```ruby
class Field
  def bind_to(ref)
    raise "already bound" if @bound
    property = TYPE_TO_PROPERTY[@type] || :value
    @component.bind_input(ref, @value_signal, property: property)
    ref.on(:blur) { @touched_signal.value = true }
    @bound = true
  end
end
```

`f.field :name` (ref 省略) で構築された Field は `@bound = false`
状態。scanner が `data-field` の input を発見した時点で `bind_to` を呼ぶ。
ref 指定済みの field に `bind_to` を呼ぶと raise(double-bind 防止)。

### 18.2.1 `Lilac::FieldComponent` 基底クラス

```ruby
module Lilac
  class FieldComponent < Component
    attr_reader :value

    # subclass で override 可。type 別に sensible default を返す。
    def initial_value
      ""
    end

    def setup
      @value = signal(initial_value)
      # subclass が super を呼んでから固有の signal を追加する
    end

    def reset
      # subclass が @value を Computed で上書きしている場合は no-op 寄り
      # の動作にする(silent return)。signal なら値を戻す。
      if @value.respond_to?(:value=)
        @value.value = initial_value
      end
    end
  end
end
```

`Field#initialize` の `source:` 受け取りロジック:

```ruby
class Lilac::Form::Field
  def initialize(name:, source: nil, initial: nil, ref: nil,
                 component:, type: :text, validator: nil, form: nil)
    raise ArgumentError, "source: と initial: は同時指定できません" if source && initial

    if source.is_a?(Lilac::FieldComponent) ||
       (source && source.respond_to?(:value) && source.respond_to?(:reset))
      # FieldComponent 経由(またはそれ相当の duck-typed component)
      @value_signal = source.value
      @source_component = source       # reset 伝播対象
      @external_value = true
    elsif source
      # 生 Signal / Computed
      @value_signal = source
      @source_component = nil          # reset 伝播なし
      @external_value = true
      Lilac.logger.warn "field :#{name} source is a raw signal; form.reset will not propagate" if dev_mode?
    else
      # 通常 field: 内部 signal を所有
      @value_signal = component.signal(initial || sensible_default_for(type))
      @source_component = nil
      @external_value = false
    end

    # 以降の dirty/touched/server_error/validator setup は通常と共通
    # bind_input は @external_value? なら skip(子 component 側 bind 済み)
  end
end
```

`Form#reset` 側:

```ruby
class Lilac::Form
  def reset
    @fields.each_value do |field|
      if field.external_value?
        # source 経由 — value signal は触らない
        src = field.source_component
        src.reset if src && src.respond_to?(:reset)
        field.reset_meta_only           # dirty/touched/server_error のみ
      else
        field.reset                     # value_signal + meta 全部
      end
    end
    @submit_attempted_signal.value = false
    clear_base_error
  end
end
```

### 18.3 `Component#form` の dual-purpose 実装

block 有無で登録 / 参照を切り替える。**同名 form の再登録は禁止**:

```ruby
def form(name = :default, &block)
  @form_registry ||= {}
  if block
    if @form_registry.key?(name)
      raise Lilac::Error,
            "form #{name.inspect} is already declared in this component " \
            "(use `form.reset` to clear values, or a different name for a new form)"
    end
    f = Lilac::Form.new(self)
    @form_registry[name] = f
    block.call(f)
    f
  else
    # auto-create: name が default でも named でも、無ければ空 Form を作る
    # (scanner からも Ruby 直接呼び出しからも同一の挙動。「Ruby ゼロ宣言
    #  + HTML だけ」のコンポーネントを成立させるため)
    @form_registry[name] ||= Lilac::Form.new(self)
  end
end
```

- block あり: registry に登録、Form を返す。同名既存なら raise
- block なし: registry から取り出す、無ければ空 Form を auto-create
  (default / named いずれも、§4 参照)

form の resource (signal / computed / bind_input listener) は構築時に
`component.signal` / `component.computed` / `component.bind_input` 経由で
**component の DisposableSet に既に登録**されている。よって component
unmount 時に通常の effect cleanup と一緒に自動解放される。Form 専用の
`dispose` API は不要。

### 18.4 scanner の form 解決アルゴリズム

scanner は DOM を **one-pass** で走査し、収集した directive を **2 段階で
処理** する(走査自体は 1 回だけ、内部の処理順序を組み替える)。設計判断の
rationale は [`lilac-decisions.md §8`(scope)](./lilac-decisions.md) /
[`§11`(2-phase processing)](./lilac-decisions.md)。

```
Phase 1: DOM walk (one pass)
  - DOM を root から DFS で 1 回だけ歩く
  - 各要素で data-form / data-field / data-button / data-text / data-on-*
    / data-class / ... 等の directive を検出して record list に追加
  - record は (element, directive name, value, ancestor data-form scope name)
    のタプル。この時点では bind/wire しない(form 状態がまだ未確定のため)

Phase 2: form 状態確定(reorder で先に処理)
  - record list の中から data-field / data-button だけを先に処理:
    a. data-field/button 要素から ancestor を **自 component subtree
       内のみ** で遡る(component 境界で停止)
       - 最初に見つかった <form> 要素の data-form 値が form 名
         (data-form 無しの素の <form> なら名前 :default)
       - <form> 要素が見つからなければ default 無印 form を使う
       - form の所有者は常に自 component(子 component subtree は scan
         しないので所有関係に曖昧さが無い)
       - 走査中に <form> 以外の要素に data-form 属性を見つけたら
         Lilac::Error raise(§11.2.1)
       - 走査中に <input form="..."> を見つけたら Lilac.logger.warn で
         1 回警告(§11.2.2)、属性は無視
    b. self.form(name) で Form を取得(無ければ auto-create、§4)
    c. data-field: 対応 field が未宣言なら HTML から auto-register
       (§11.3.1)。既に Ruby で f.field 宣言済みならそれを使う
       - 同 form への同名 field の重複 register は raise Lilac::Error
         (Ruby + HTML 重複、typo 検出)
    d. data-button: 対応 button が未宣言なら raise Lilac::Error
       (button は handler 本体が必須なので auto-create 不可)

Phase 3: wire pass(全 directive を bind)
  - record list 全体を走査順序で wire:
    - data-field: bind_input + container class/error wire
    - data-button: click handler wire
    - data-text / data-class / data-show / data-on-* / ... :
      form 状態が確定済みなので、computed 内で form[:X].value を読む
      directive が安全に動く
```

この 2 段階により「`<input data-field="text">` が DOM 上で
`<p data-text="@upper">`(computed が `form[:text].value.upcase` を読む)
の **後** に出現しても、wire 時点では field が既に register 済み」が
保証される。DOM 走査は 1 回のみなので、要素数 N に対し O(N) のまま。

form scope ルールは単純: **自 component subtree 内の ancestor `<form>`
要素が scope を決める**(`<form data-form="foo">` → `:foo`、素の `<form>`
→ `:default`、`<form>` 無し → 自コンポーネントの default form)。
`data-form` を `<form>` 以外の要素に書いたら raise(§11.2.1)。`form=""`
属性は warn で無視(§11.2.2)。form が Ruby で declare されていなくても
scanner phase 2 で auto-create されるので「Ruby ゼロ宣言 + HTML だけ」の
コンポーネントも成立する。

**子 component subtree は scan しない**: scanner は `data-component`
を見つけたらその subtree の下降を停止する(他コンポーネントの directive
は他コンポーネントの scanner が処理する)。これにより:
- 子 component の `<input data-field>` が親 form に勝手に書き込む事故が
  起きない
- form の所有者が常に明確(scan を実行している component 自身)
- どこに field があるか grep で完全に追える

stateful な子 input component を親 form の field として組み込みたい
場合は、§5 の `f.field :name, source: refs.X.component` パターンを
使う(§3.1 / §5 参照)。

### 18.4.1 `<button type="submit">` の特別 wire(:submit handler)

scanner が `<form>` 要素を発見した時点で、その `<form>` の submit イベント
を form の `:submit` handler に結線する。`<form>` の `data-form` 属性の
有無は問わない(素の `<form>` は `:default` form):

```ruby
# 概念: scanner が <form data-form="X"> または素の <form> を発見した時点
# (この時点で scanner は自 component の subtree を歩いている = host = self)
form_name = form_el.data_attr("form") || :default
form_el.on(:submit) do |event|
  event.call(:preventDefault)
  self.form(form_name).invoke_button(:submit, event)
end
```

具体的には:
- `<form>` element に1回だけ submit listener を登録
- Enter キーによる暗黙 submit や `<button type="submit">` の click は
  `<form>` element の submit イベントに集約され、`:submit` handler が呼ばれる
- `:submit` handler が登録されていない form の submit は ignore(form
  field 入力中に Enter を押しても何も起きない、自然挙動)
- `event.preventDefault()` は scanner 側で常に呼ぶ(ページリロード防止)

`<button type="submit">` を **ancestor `<form>` 無し** で発見した場合:
- dev_mode で warn(`Lilac.logger.warn "<button type='submit'> outside <form>; ignored"`)
- 何も wire しない(browser default も `<form>` ancestor が無いので発火しない)

### 18.4.2 `Form#button` / `Form#invoke_button` の実装

```ruby
class Lilac::Form
  def button(name, validate: true, &handler)
    raise ArgumentError, "block required" unless handler
    @buttons ||= {}
    @buttons[name.to_sym] = { handler: handler, validate: validate }
    nil
  end

  # button 経由の発火。event は scanner からの呼び出し時に渡される
  # (browser default の preventDefault は scanner 側で行う)。
  # handler 自体は event を受け取らない設計(submit 結果は values で
  # 完結する)。プログラム経由 (`form.invoke_button(:save)`) は event
  # を省略可。
  def invoke_button(name, _event = nil)
    sym = name.to_sym
    spec = @buttons[sym] or
      raise Lilac::Error, "form has no button :#{sym} (declare via f.button :#{sym} do ... end)"
    if spec[:validate]
      submit { |snapshot| spec[:handler].call(snapshot) }
    else
      # validate skip: Form#values で現在値を snapshot して handler を即呼ぶ
      # (submit_attempted は立てず、touch all も走らない、エラー表示も
      # 出ない。"validation を要求しない action" の意味)
      spec[:handler].call(self.values)
    end
  end
end
```

`validate: true` の handler は `Form#submit` lifecycle (submit_attempted →
touch all → validate → handler) に乗る。`validate: false` は validity を
問わず current `values` を集めて即 invoke。

### 18.5 既存 `@form` ivar との互換

`form do |f| ... end` (name 省略 = `:default`) の戻り値を ivar に代入する
既存パターン(`@form = form { ... }`)は維持可能。registry にも入るので、
HTML から `data-field` で参照される時は registry から引かれる。両方の
代入が同じインスタンスを指すので問題なし。

参照経路の比較:

```ruby
@form = form do |f| ... end       # 登録 + ivar 保持

@form.submit { ... }              # ivar 経由
form.submit { ... }               # registry 経由 (block なし呼び出し)
# 上記2行は同じ Form を呼ぶ
```

新規コードは ivar を持たず `form` / `form(:name)` で都度引く方が簡潔。
既存コードの ivar パターンを書き換える必要は無い。

### 18.6 form gem の主要 API 一覧

`FormBuilder` (Component に include):

```ruby
module FormBuilder
  include Lilac::Form::Validators

  def form(name = :default, &block)
    @form_registry ||= {}
    if block
      raise Lilac::Error, "form #{name.inspect} already declared" if @form_registry.key?(name)
      f = Lilac::Form.new(self)
      @form_registry[name] = f
      block.call(f)
      f
    else
      # block 無し: 取り出す、無ければ auto-create(default/named とも)
      @form_registry[name] ||= Lilac::Form.new(self)
    end
  end
end
```

主要 API:
- `Lilac::Form#submit { |values| }` — submit lifecycle 入口(submitter 引数なし、multi-button 分岐は `f.button` で表現)
- `Lilac::Form::Field#bind_to(ref)` — deferred binding(§18.2)
- `Lilac::Form#field(name, ref: nil, initial: nil, source: nil, type: :text, &validator)` — `ref:` / `initial:` は optional、`source:` は polymorphic(`FieldComponent` / Signal)
- `Lilac::FieldComponent` — 基底クラス(`attr_reader :value` / `initial_value` / `reset` 提供、§18.2.1)
- `Lilac::Form#reset` — `source:` 経由 field については `FieldComponent` の `reset` を伝播(§7 / §18.2.1)
- `Lilac::Form#button(name, validate: true, &handler)` — named action 宣言(§8)
- `Lilac::Form#invoke_button(name)` — scanner / プログラム経由の button 発火(§18.4.2)
- `mruby-lilac-form` は全 build variant に同梱(§18.1)

---

## Status of this spec

本ドキュメントは Lilac form 機能の **現行実装の canonical 仕様**。Part I〜VI
すべてが実装済みの API / 挙動を記述する。実装履歴の概要は §17 に、実装上の
技術的詳細は §18 にまとめてある(具体的な差分は git log を SSOT とする)。
