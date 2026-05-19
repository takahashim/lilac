# Lilac Props Spec

`data-prop-*` 属性経由で component に declarative な configuration を渡す
ための仕様。form-spec とは独立した直交概念。

P2 以降、`prop :X` は単なる「値を読む宣言」ではなく **`@X` Signal ivar の
auto-init 宣言 + 同名 public reader の auto-define** を兼ねる。template の
`@X` 記法および Ruby の `instance.X` accessor の両方から prop 値が読める。
親側は `data-prop-X` の値に `it.field` / `@ivar` 式も書けるようになった
(parent の **per-row scanner** が clone-time に解決)。この値式サポートは
`data-each` 配下の row component 向けで、static nested component の
`data-prop-x="@parent_signal"` まではまだ一般化されていない(§7.5, §11)。

文書は 4 つの Part に分かれる:

| Part | 範囲 | 内容 |
|---|---|---|
| I — Foundation | §1-§3 | 目的・非目標・基本モデル |
| II — Ruby DSL | §4-§5 | `prop` 宣言、`@X` ivar、`props` accessor、`update_prop` |
| III — HTML | §6-§8 | `data-prop-X` 属性、型変換、値式、制約 |
| IV — Implementation | §9-§10 | 実装履歴 / 実装メモ |

設計判断の rationale は [`lilac-decisions.md §12`](./lilac-decisions.md) と
[`§14`](./lilac-decisions.md)(P2 = ivar 宣言拡張)。

---

## Part I — Foundation

## 1. 目的

- component に **declarative な configuration**(label, type, max length, theme 名等)
  を HTML 属性経由で渡す
- 同じ component class を **異なる設定で複数回使う** ことを可能にする
  (LabeledInput を複数 field 用に instance 化、Counter を初期値違いで複数配置 等)
- 「props 機構が無いので component を再利用しにくい」現状の制約を解消

## 2. 非目標

- **reactive な値の受け渡し**(form の `source:` パターンが担当、
  [`lilac-form-spec.md` §5](./lilac-form-spec.md))
- **複雑なオブジェクト/配列の serialization**(Hash / Array / JSON 等は対象外。
  必要なら複数の primitive prop に分解する慣行で対応)
- **mount 後の動的変化**(現バージョンは read-once、§11 で将来候補)
- **type 安全な validation**(`String` / `Integer` / `Float` / `Boolean` の 4 type
  のみ、custom validator や complex pattern は非目標)

## 3. 基本モデル

```
<div data-component="Counter"           ← component 起動
     data-prop-initial="10"             ← prop: initial = 10
     data-prop-step="2"                 ← prop: step = 2
     data-prop-label="Items">           ← prop: label = "Items"
  ...
</div>
```

```ruby
class Counter < Lilac::Component
  prop :initial, Integer, default: 0   ← @initial Signal + #initial reader を宣言
  prop :step,    Integer, default: 1
  prop :label,   String                 ← 必須(default なし)

  def setup
    # @initial, @step, @label は既に Signal として init 済み。
    # 値が要るときは accessor (`initial`, `step`, `label`) か `.value` で読む。
    @count = signal(initial)
  end
end
```

template からも `@X` で参照可能(`@initial` は通常の Signal ivar として読める):

```html
<span data-text="@label"></span>           <!-- prop の現在値が反映される -->
<span data-text="@count"></span>            <!-- 通常の signal も同様 -->
```

mount 時 (Component lifecycle):
1. scanner が `data-component="Counter"` を発見、Registry が Counter を instantiate
2. `Component#prepare_setup_phase`: `Props.build` が `data-prop-*` を読んで型変換、
   prop ごとに `Signal.new(value)` を生成
3. `Component#install_prop_ivars!`: 各 Signal を `@NAME` ivar に set、`@_prop_signals`
   に originals を記録 (override 検出用)
4. `Component#mount` → `setup` 実行 (この時点で `@X` ivar / `#X` accessor が使える)
5. `Component#mount` → `validate_prop_ivars_not_overwritten!` (= setup で
   `@X = signal(...)` 等の reassign がないか identity 比較で検査、あれば raise)
6. `Component#mount` → `bind_template_hook` (directive scanner で bindings 配線)

`@X` Signal そのものは **mount 時に作られたら identity が固定**。値の更新は
`update_prop` または `@X.value = ...` で行う。Signal の再代入は raise (§8.2)。

---

## Part II — Ruby DSL

## 4. `prop` 宣言

```ruby
class MyComponent < Lilac::Component
  prop :NAME, TYPE [, default: VALUE]
end
```

宣言一つで以下 3 つを束ねる:

1. `Props.build` が `data-prop-NAME` 属性を読んで型変換し、`Signal` を生成
2. `install_prop_ivars!` が生成した Signal を `@NAME` インスタンス変数に set
3. `define_method(:NAME)` が同名の public reader を生成 (`instance.NAME` で
   `@NAME.value` を返す)

### 4.1 引数

- **`NAME`** (Symbol、必須): prop 名。`:max_length` のように snake_case
- **`TYPE`** (Class、必須): `String` / `Integer` / `Float` / `Lilac::Boolean` のいずれか
- **`default:`** (任意): 属性が HTML に無い場合の値

### 4.2 必須 / optional の判定

| 宣言 | HTML に属性無し時 |
|---|---|
| `prop :label, String` | mount 時 `Lilac::Error` raise(必須) |
| `prop :label, String, default: "Untitled"` | `"Untitled"` を採用 |
| `prop :label, String, default: nil` | `nil` を採用(明示的に nil 許容) |

### 4.3 例

```ruby
class LabeledInput < Lilac::FieldComponent
  prop :label,       String                          # 必須
  prop :type,        String,  default: "text"        # optional
  prop :max_length,  Integer, default: nil           # optional, nil 許容
  prop :required,    Lilac::Boolean, default: false  # optional
  prop :placeholder, String,  default: ""
end
```

### 4.4 予約名

framework が Component の lifecycle で使う ivar 名と衝突する prop 名は
宣言時 (= class loading) に raise する:

```
root, refs, parent, props, children, exposed,
resources, scope_stack, prepare_setup_phase_done,
mounted, unmounted, error_handler, abort_controller,
_prop_signals
```

framework method 名 (例: `signal`, `bind`, `wrap` 等) と衝突する prop は
runtime 上では `define_method` で override されるので、Ruby の通常の挙動
として宣言時に raise はしない (ユーザ責任、setup 内で `signal(...)` が
呼べなくなる等は実行時の ArgumentError 等で気付く)。

## 5. 値の読み方 — 3 つの経路

`prop :label, String` を宣言した component には次の 3 つの読み出し path が
同時に提供される。どれも同じ Signal の現在値を返す:

| 経路 | 例 | 用途 |
|---|---|---|
| `@label` ivar | `@label.value` / `effect { puts @label.value }` | template の `data-text="@label"` 等、reactive subscription も自然 |
| `instance.label` accessor | `item = component_for(event[:target]); item.label` | 親や外部からの value 読み出し (event handler 等) |
| `instance.props.label` | `inst.props.label` | back-compat の read-through。`props.has?` / `props.to_h` 等の補助 API と組で使う |

### 5.1 `instance.NAME` accessor (P2 で追加)

`prop` 宣言は自動的に同名 public reader を `define_method` する。実装は
`instance_variable_get(:"@NAME").value` と等価。reactive context (effect /
computed) 内で読めば `.value` が走るので Signal への購読が成立する。

```ruby
class TodoItem < Lilac::Component
  prop :id, Integer
  prop :title, String
end

# 外部から:
item = component_for(event[:target])
item.id      # → 1   (Integer)
item.title   # → "Read the spec"  (String)

# 内部から(effect 内):
class TodoItem
  def setup
    effect { puts "title changed to #{title}" }  # title accessor が .value 経由で購読
  end
end
```

### 5.2 `props.X` accessor (P1 維持、read-through)

```ruby
def setup
  props.label          # → "Email" — @label.value と等価
  props.has?(:label)   # → true
  props.to_h           # → { label: "Email", ... }
end
```

| メソッド | 戻り値 |
|---|---|
| `props.NAME` | 該当 Signal の現在値 (`.value`) |
| `props.has?(name)` | 宣言済みか(default のみで attribute 無し時も `true`) |
| `props.to_h` | 全 prop の `{name => current_value}` Hash |

未宣言の prop にアクセス(`props.unknown_prop`)は `NoMethodError`(raise)。

### 5.3 `Component#update_prop(name, raw_value)` — 外部更新 API

主に親側の per-row scanner が row 再利用時に呼ぶ runtime 内部 API。Signal の
identity を保ったまま `.value =` で値を更新するため、override 検査を triggers
せず、購読中の effect / computed は再評価される。

```ruby
child.update_prop(:title, "new title")
# 内部的に:
#   sig = child.instance_variable_get(:@title)
#   sig.value = Props.coerce("new title", String, "data-prop-title", "Child", name: :title)
```

ユーザコードからの直接呼び出しは想定外。`data-prop-X="it.field"` の row reuse
の autom 更新経路 (Scanner) からのみ呼ばれる。型 coerce ルールは初回 `Props.build`
と同じ。

### 5.4 使い分けの目安

- template の binding: **`@X`** (一番自然)
- 外部から特定 component の値を読む: **`item.X`** (`item.props.X` でも可、好み)
- 全 props を Hash で扱う / 存在チェック: **`props.has?` / `props.to_h`**

---

## Part III — HTML

## 6. `data-prop-X` 属性

### 6.1 属性名

```html
<div data-component="Counter"
     data-prop-initial="10"          → props.initial
     data-prop-max-length="100"      → props.max_length
     data-prop-on-change="handler">  → props.on_change
```

- prefix は **`data-prop-`**
- kebab → snake_case 自動変換(`max-length` → `max_length`)
- 大文字小文字は HTML 仕様通り attribute は case-insensitive(scanner は lower 化)

### 6.2 配置

- prop 属性は **`data-component="X"` を持つ要素そのもの** に書く
- 子孫要素の `data-prop-*` は **無視**(その component の props として扱わない)
- ネストした他 component(`data-component="Y"`)の `data-prop-*` はその Y の props

```html
<!-- Counter component の props -->
<div data-component="Counter" data-prop-initial="5">
  ...
</div>

<!-- Counter の props にならない(div の attribute としては存在するが Lilac は無視)-->
<div data-component="Counter">
  <p data-prop-foo="bar">...</p>
</div>
```

### 6.3 値が無い属性(presence-only)

```html
<div data-component="Modal" data-prop-open>  <!-- Boolean prop のみ true 扱い -->
```

詳細は §7.4 Boolean 規約参照。Boolean 以外の type で presence-only 属性は
**型変換失敗で raise**(空文字を Integer 変換できない等)。

## 7. 型変換規約

HTML 属性値はすべて文字列。各 type ごとの変換ルール:

### 7.1 String

無変換、HTML 属性値そのまま。

| HTML | Ruby |
|---|---|
| `data-prop-label="Email"` | `"Email"` |
| `data-prop-label=""` | `""` |
| `data-prop-label`(値なし) | `""` |

### 7.2 Integer

`Integer(value)` 厳密変換、失敗で raise。`to_i` の silent fallback は採用しない
(typo 検出優先)。

| HTML | Ruby |
|---|---|
| `data-prop-step="5"` | `5` |
| `data-prop-step="-3"` | `-3` |
| `data-prop-step="0"` | `0` |
| `data-prop-step="5x"` | `Lilac::Error` raise |
| `data-prop-step=""` | `Lilac::Error` raise |
| `data-prop-step="3.14"` | `Lilac::Error` raise(Float は Integer にしない) |

### 7.3 Float

`Float(value)` 厳密変換、失敗で raise。

| HTML | Ruby |
|---|---|
| `data-prop-rate="0.5"` | `0.5` |
| `data-prop-rate="3"` | `3.0`(Integer リテラルは OK) |
| `data-prop-rate="abc"` | `Lilac::Error` raise |

### 7.4 Boolean

**ハイブリッド規約**: `"true"` / `"false"` を canonical、presence shortcut も
許容、それ以外の文字列は raise(typo 検出)。

| HTML | Ruby |
|---|---|
| `data-prop-disabled="true"` | `true` |
| `data-prop-disabled="false"` | `false` |
| `data-prop-disabled`(値なし) | `true`(HTML 慣行の presence shortcut) |
| `data-prop-disabled=""`(空文字) | `true`(presence shortcut と同等) |
| `data-prop-disabled="yes"` | `Lilac::Error` raise |
| `data-prop-disabled="1"` | `Lilac::Error` raise |
| `data-prop-disabled="on"` | `Lilac::Error` raise |
| 属性 missing | default 値(`default:` 未指定なら raise) |

設計の根拠: `<input disabled>` のような HTML 標準書き方を許容しつつ、
`"yes"` / `"1"` / `"on"` 等の曖昧表現は禁止する。

### 7.5 値式 (`@ivar` / `it.field`) — P2 で追加

`data-prop-X="..."` の値は、特定 syntax を満たすと **parent component の
context で式として評価され、scalar 値に解決されてから child の Props.build
に渡される**。

| 値の形 | 解釈 |
|---|---|
| `data-prop-x="hello"` | 静的 literal (従来通り) |
| `data-prop-x="@foo"` | parent の `@foo` Signal の現在値 → `.to_s` |
| `data-prop-x="bare_ident"` | **literal として扱う**(bare ident は他 directive では iteration item field を意味するが、`data-prop-*` だけは literal fallback を優先。iteration item の field を渡したい場合は §7.6 auto-fill を使う) |

解決のタイミング:
- **fresh row clone 時** (data-each の最初の iteration): parent の per-row
  scanner が `resolve_props(row_el, item)` を呼び、属性に scalar を書き戻す
- **row reuse 時** (同 key の item が変化したとき): parent の scanner が
  template の原本から式を recover し、`child.update_prop(name, new_value)`
  で signal を mutate (詳細 §10.5)

iteration row を component に切り出すパターン
(`<ul data-each="@items"><li data-component="Row">...`) は §7.6 の
**prop auto-fill** が canonical。child の `prop :id, :title` 宣言だけで
iteration item の同名 field が auto-init される(`data-prop-X` を書く必要なし)。

**制約**:
- `@x` は **parent の setup が走ったあと**でしか resolve できない。よって
  parent の `data-each` 配下に限り保証され、それ以外の static nested
  data-component の `data-prop-x="@parent_signal"` は parent.setup より先に
  child の Props.build が動くので current 未サポート (将来 P3 で検討)
- 解決値の `.to_s` 変換後に child 側の型 coerce が走る。Hash 等の複雑値を
  直接渡すユースケースは非対応 (個別 primitive prop に分解する)

### 7.6 Iteration item からの prop auto-fill (data-each scope)

`data-component` 要素が `data-each` body に置かれている場合、child component
の `prop :X` 宣言は **同名 field を iteration item から auto-init** される。
`data-prop-X` を明示しなくても child の `@X` ivar が item の `item["X"]`
で埋まる。

#### 用例

```html
<ul data-each="@items" data-key="id">
  <li data-component="Row">
    <!-- @id / @title / @qty は item から auto-fill される -->
  </li>
</ul>
```

```ruby
class Row < Lilac::Component
  prop :id, Integer
  prop :title, String
  prop :qty, Integer
  # mount 時、item["id"] / item["title"] / item["qty"] から各 prop が auto-init
end
```

`data-prop-X` を一切書かなくても済むため、`data-prop-id="it.id"
data-prop-title="it.title" data-prop-qty="it.qty"` の forest が解消される。

#### Lookup priority

child が `prop :X` を宣言しているとき、`X` の値は以下の順で決定:

1. 同要素に **`data-prop-X="..."` が明示** されていればそれ(§7.5 の式解決)
2. iteration context にあり item が key **`"X"` / `:X`** を持てば
   `item["X"]` を使う(ItemField lookup: Hash sym → str → public_send)
3. prop 宣言に **`default:`** があればそれを使う
4. else: **required prop missing error**

literal で override したいときは `data-prop-X` を明示するだけ:

```html
<li data-component="Row" data-prop-mode="edit">
  <!-- @id / @title / @qty は item から auto、@mode は literal "edit" -->
</li>
```

#### Row reuse 時の挙動

`data-each` の row 再利用(同 key の item が更新)で、auto-fill 経路の prop
も **fresh item の値で `update_prop` 呼び出し** が走る(明示式と同じ flow、
§10.5)。explicit `data-prop-X` 式と auto-fill が混在しても、explicit 側が
priority 1 で onto 同じ signal を更新するので結果は決定的。

#### 制約

- 適用されるのは **data-each body 内の data-component** のみ。`data-each`
  の外で data-prop-X 省略は従来通り「required prop missing error」
- item が Hash で無い場合(Data / Struct 等)は `public_send(prop_name)` を
  呼ぶ。`prop` 名と item のメソッド名が衝突しないよう注意
- field が **nil** または item に key が無い場合は auto-fill skip → priority 3
  (default)に進む。これにより「optional な field を任意で持つ item」も
  扱える
- 実装は `Lilac::Directives::PropAutoFill` モジュールに集約
  (`runtime/mruby-lilac-directives/mrblib/lilac_directives_prop_auto_fill.rb`)。
  Scanner からは `fill_attributes(el, item)`(初回 mount) /
  `push_updates(row_node, item, skip_exprs, host:)`(reuse)の 2 経路で呼ばれる

## 8. 制約・エラー

### 8.1 mount 時に error として通知されるケース

以下は **mount 時に `Lilac::Error` が raise される** が、`Lilac::Component`
の error_boundary 機構経由で **logger.error に routes される**。`Lilac.start`
そのものは中断せず、該当 component の `@props` は空 `Props.new({})` に
fallback して page 全体の mount は continue する(後続の `setup` で
`props.X` を読むと `NoMethodError` になり、これもまた error_boundary 経由
で logger に流れる):

- **必須 prop の attribute 無し**: `prop :label, String`(default なし)で
  HTML に `data-prop-label` が無い
- **型変換失敗**: `Integer("abc")` 等
- **Boolean 規約違反**: `"yes"` / `"1"` / `"on"` 等
- **未サポート type**: `prop :x, Symbol` 等(現バージョンは String / Integer
  / Float / `Lilac::Boolean` のみ)

エラーメッセージ例(`Lilac.logger.error` 経由で stderr 等に出力される、
利用者が `begin; Lilac.start; rescue; end` で catch する想定では **ない**):
```
[Lilac] Error in Counter#props
  Lilac::Error: data-prop-step="abc" cannot be converted to Integer
    in component Counter

[Lilac] Error in LabeledInput#props
  Lilac::Error: required prop :label is missing in component LabeledInput
    (declare default via `prop :label, ..., default: ...`)
```

利用者側で個別に handling したい場合は `Lilac::Component.error_boundary
do |label, err| ... end` を宣言する(他 lifecycle エラーと同じ機構)。

### 8.2 prop ivar の override 検出 (mount 時 raise)

`prop :title` で auto-init した `@title` Signal を setup 内で **再代入** する
と `Lilac::Error` raise(logger.error 経由で routed)。Signal identity の
比較で検出する(`@_prop_signals[:title]` に保管した original を
`@title.equal?(original)` で照合、mount lifecycle の `:prop_ivars` step):

| 書き方 | 検出 |
|---|---|
| `@title = signal("x")` | **raise** (新 Signal、identity 変化) |
| `@title = nil` | **raise** (nil、identity 変化) |
| `instance_variable_set(:@title, ...)` | **raise** |
| `@title.value = "x"` | OK (同じ Signal の mutate) |
| 何もしない | OK |

エラーメッセージは 3 つの修正方針を提示する:
```
TodoItem: setup overwrote `@title` which was auto-initialized by `prop :title`.
Use one of:
  - mutate the prop's signal:  @title.value = ...
  - derive a new ivar:          @upper = computed { @title.value.upcase }
  - rename to avoid the clash
```

### 8.3 dev_mode warning

- **未宣言の `data-prop-X` 属性**: component class が `prop :X` を宣言して
  いないのに HTML に `data-prop-X="..."` がある場合、`Lilac.logger.warn` で
  1 回警告(typo 検出)
  ```
  data-prop-labl="Email" on <div data-component="LabeledInput"> —
    no `prop :labl` declared. typo of `data-prop-label`?
  ```

- **`data-prop-X` を `data-component` 要素以外に書く**: silent skip
  + dev_mode warn(props として読まれないことを明示)

### 8.4 silent な挙動

- attribute 無し + default あり → default 採用(silent、warn なし)
- `props.X` を setup 内で参照しない → 値は使われないがエラーなし

---

## Part IV — Implementation

## 9. 実装履歴 / Phase 内訳

実装は `runtime/mruby-lilac/mrblib/lilac_props.rb` に集約。詳細な差分は
git log を SSOT とする(本 table は要約)。

| Phase | 内容 | ステータス |
|---|---|---|
| **P1** | 最小実装: `prop` DSL、`props` accessor、String / Integer / Float / Boolean の 4 type、default、kebab → snake 変換、必須 raise、型変換 raise、dev_mode warn、core 統合 | 完了 |
| **P2** | `prop` = `@X` Signal ivar 宣言 + 公開 reader 兼用、`data-prop-X` 値式 (`@ivar` / `it.field`) 解決、override 検出、`update_prop` 外部更新 API、`Component#component_for` / `defer_until_bound`、Scanner `register_each_binding`、Sortable::Item `by:` / Sortable::List `sortable_target` 1 引数化 | 完了 |
| **P3** | parent signal の継続追従 (`data-prop-x="@signal"` の signal 変化を child の Signal に effect で伝達) | 未着手(実需待ち) |
| **P4** | change callback(`X_prop_changed(old, new)` メソッド自動呼び出し)、type 拡張 (Symbol / Enum) | 未着手(実需待ち) |

P2 まで完了で以下が成立:
- `<ul data-each="@items"> <li data-component="Row" data-prop-id="it.id">` の宣言的 row component
- template の `@X` から prop 値を直接読む / `instance.X` で外部から読む
- row reuse 時の自動値更新 (Scanner → `update_prop`)
- override (`@X = signal(...)`) は raise で早期検知

P3 以降は §11 将来候補として記録、実需が発生した段階で着手する。

## 10. 実装メモ

### 10.1 mount flow への統合

```
scanner が <div data-component="X"> を発見
  ↓
component class X を Registry から lookup
  ↓
data-prop-* 属性を収集、X の prop 宣言と突合
  ↓
型変換、必須 check、props object 生成
  ↓
component.props = props_object (instance attr)
  ↓
component.setup を呼ぶ(従来通り)
```

### 10.2 実装の SSOT

`prop` DSL / `Props.build` / `Props.coerce` / `install_prop_ivars!` /
`validate_prop_ivars_not_overwritten!` / `update_prop` の正確な実装は次の
2 ファイルに集約:

- `runtime/mruby-lilac/mrblib/lilac_props.rb` — `Props` クラスと build / coerce
- `runtime/mruby-lilac/mrblib/lilac_component.rb` — `prop` class-method、
  mount lifecycle (`install_prop_ivars!` / `validate_prop_ivars_not_overwritten!` /
  `update_prop`)

本 spec は contract と semantics を SSOT として持ち、実装の細部 (型変換の
コード片、`Lilac::Boolean` sentinel の判定方法等) は実装ファイル側に委ねる。
これにより spec がコード変更に追従しない drift を防ぐ。

### 10.3 `mruby-lilac-props` gem の位置付け

- form gem と同じく core 統合(全 variant 同梱)
- 実装規模が小さい(< 200 行)ため `mruby-lilac` 本体(`runtime/mruby-lilac/mrblib/lilac_props.rb`)
  に物理統合済み(別 gem は作っていない)

### 10.4 既存 component への影響

- `prop` 宣言を書かなければ何も変わらない(後方互換)
- 既存 component が HTML 側に `data-prop-X` 属性を持っていなければ無影響
- 新 component で props を使い始められる

### 10.5 Row reuse 時の `update_prop` 呼び出しフロー

`<ul data-each="@items"> <li data-component="Row" data-prop-id="it.id">` で
bind_list が同一 key の row を再利用するとき、Scanner.dispatch_each は:

1. row template から `data-prop-*` 属性の値式を事前抽出 (`extract_row_prop_exprs`)
2. bind_list の per-item block で prev_t (再利用 row) を検出
3. `Lilac.find_for_element(row_node)` で既 mount の child Component を取得
4. 各 prop 式を新 item で再評価し、`child.update_prop(name, new_value)` で
   Signal の `.value =` を呼ぶ → 既存 effect / computed が再評価
5. `child.update_prop` 内部で `Props.coerce` が原始 build と同じ型変換を実行

`resolve_props` (clone 時の属性書き戻し) は fresh clone と reuse で属性を
上書きするが、template の原本 (Scanner が `tpl[:content][:firstElementChild]`
を保持) には触れないので、reuse 時の式抽出は問題なく動く。

### 10.6 `Component#component_for(element_js)` (P2 で追加)

`Lilac.find_for_element` の instance-method 別名。`setup` block 内で
`Lilac.` prefix なしに使える。

```ruby
root.on(:item_dismissed) do |event|
  item = component_for(event[:target])  # ← Lilac.find_for_element の短縮
  next unless item
  @items.update { |arr| arr.reject { |it| it["id"] == item.id } }
end
```

self を使わない pure lookup だが、DSL ergonomics を優先して Component に
置いている (`wrap` の近隣)。

---

## Status of this spec

P1-P2 は完了済み(`runtime/mruby-lilac/mrblib/lilac_props.rb`)で、
本ドキュメントは現行実装の canonical 仕様。未着手なのは P3-P4
(parent signal の継続追従、change callback / type 拡張 等)で、方向性は
§11 将来候補を参照。

## 11. 将来候補(検討待ち)

### P3: Parent signal の継続追従

`data-prop-x="@parent_signal"` で渡した時、parent の signal が変化したら
child の `@x` Signal にも反映する。現状は初回 mount / row reuse の 2 つの
タイミングだけ反映され、parent signal が任意のタイミングで変化しても child
には伝わらない。

実装方針案: parent の per-row scanner が `@parent_signal` を読む effect を
立て、変化を `child.update_prop(:x, new_value)` でブリッジする。child の
scope ではなく parent の scope に effect が乗るので、parent unmount 時に
自動 dispose される。

### Change callback

Stimulus 風の `x_prop_changed(old, new)` メソッド自動呼び出し。reactive props
と組み合わせて使う。

### MutationObserver 経由の動的属性変化

mount 後に `data-prop-X` 属性を **外部 (Lilac の外側) から書き換え** たとき
の検知。`prop :x, String, observe: true` 等で opt-in。実需が稀なので保留。

### Symbol type

`prop :align, Symbol, default: :left` で `Symbol` 化。mruby Symbol leak 対策
として、列挙値は事前に Symbol を intern しておく必要があり、ユーザの責任になる。
実需があれば追加検討。

### Enum 型(値の制約)

`prop :align, String, in: %w[left center right]` で許容値を制約。
type 変換と value validation の両方を提供する形。

---

## Cross-references

- form spec での props 活用: [`lilac-form-spec.md`](./lilac-form-spec.md)
  の `LabeledInput` 例(§3.1)、`FieldComponent` との組み合わせ
- 設計判断: [`lilac-decisions.md §12`](./lilac-decisions.md)
- Lilac 全体仕様: [`lilac-spec.md`](./lilac-spec.md)
