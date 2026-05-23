# Lilac 設計判断ログ

このドキュメントは Lilac の **主要な設計判断とその rationale** を
時系列で蓄積する log。**新しい判断が出るたびに追記**する累積型 doc。

設計原則と positioning は [`lilac-design.md`](./lilac-design.md) を参照。
ここで述べる各判断は、その原則 / positioning に基づく **具体的な
適用** または **既存決定の refinement** として位置付ける。

## 各判断のフォーマット

| 項目 | 内容 |
|---|---|
| 判断 | 何を決めたか(1〜2 文) |
| 背景 | なぜこの判断が必要になったか(直前の状況、問題提起) |
| rationale | なぜこの判断を選んだか(他案との比較、原則との整合) |
| トレードオフ | 受け入れたコスト、想定される副作用 |

過去判断を **覆す** 場合は旧節を歴史として残し(節タイトル冒頭に
`(superseded by §N)` を追加)、新節で新判断を述べる。新節の rationale で
「過去 §M の判断を覆した」と言及する。

---

## 1. Runtime canonical 化(Phase 0〜4 既決)

### 1.1 判断

ランタイムが directive 解釈の **canonical** で、CLI codegen は **optional
な最適化レイヤ** とする。

### 1.2 背景

旧設計では CLI(`lilac build`)が `.lil` ファイルを HTML + Ruby に変換し、
runtime は変換後のコードを実行するだけだった。これだと:

- CLI 経由しないと宣言的 directive (`data-text="@msg"` 等) が動かない
- 「Ruby + HTML を書いてブラウザで開く」だけでは動かない
- README リードの主張("Templates stay as valid HTML5 with `data-*` directives")
  が半分嘘になる

### 1.3 判断の rationale

- **ビルド不要で動く** ことが Lilac の他フレームワークに対する固有の強み
  (Vue / React / Svelte はビルド前提)
- **入門コスト** が圧倒的に下がる(教育、CodePen 共有、デモ作成)
- **CLI の役割は静的検査と最適化** に絞れる(canonical な仕様は runtime)
- 性能影響は無視できる(release ビルドで brotli +9KB 程度の検証済み)

### 1.4 トレードオフ

- runtime バンドルが directive scanner 分大きくなる(~30KB raw、~9KB brotli)
- mount 時に DOM 走査コスト発生(微秒オーダー)
- CLI の existence rationale が「optimization」に限定される
  (要らない人にとっては不要)

---

## 2. Form を input bind の中心機構に

### 2.1 判断

input / textarea / select / checkbox の declarative binding は **form 経由
が canonical**。汎用 `data-value` / `data-checked` は廃止、form の
`data-field` directive に統一。

### 2.2 背景

旧設計では:
- `data-value="@signal"` で input ↔ signal の双方向 bind(form 不要)
- `data-checked="@signal"` で checkbox の双方向 bind
- form gem は optional な validation helper(独自 directive 無し)

これだと:
- 「form と関係しない input は data-value、form 内は f.field + bind_input」
  という二重路線
- `data-value` と `data-field` 両方あると "どっち使うべきか" の判断
  コスト発生

### 2.3 判断の rationale

- **「input は form の field」と固定** することで mental model 一本化
- form gem に validation / dirty / touched / error の概念が乗っているので、
  どんな input でも自然に状態管理できる
- `form.field :query, initial: ""` の 1 行追加で済むなら、単発 input
  のオーバーヘッドも実用上問題なし
- spec の directive 数も 2 つ減る(`data-value` / `data-checked` 削除)

### 2.4 トレードオフ

- form gem が **core 機能化**(`lilac-compiled` 含む全 variant 同梱、現状の
  optional 位置付けを変更)
- 検索ボックスやトグル等を「form」と呼ぶ違和感(API ergonomics で緩和:
  `form.field :query, initial: ""` の 1 行で済むようにする)
- imperative `bind_input` は escape hatch として残す(per-row 編集
  input 等のため、f.array 実装まで)

---

## 3. directive 値の文法を厳格に保つ

### 3.1 判断

directive 値は **identifier 参照のみ** を許す。`@ivar`、`it[.field]`、
method 名、登録名。任意 Ruby 式は禁止。

### 3.2 背景

JSX / Vue / Alpine は template 内に任意 JS 式を書ける:
```jsx
<div className={errors.email ? "invalid" : "valid"}>
```

これは柔軟だが:
- 「template でロジック」の温床(複雑な式が markup に混ざる)
- template と Ruby のどちらに logic があるかが曖昧になる
- LSP / debugger が template 内式を扱う必要が出る
- escape / interpolation で XSS バグの温床

### 3.3 判断の rationale

- Ruby 開発者は Ruby 側で logic を書きたい(template は markup の場)
- "Templates are configuration, not code" の純度を保つ
- spec / parser / lint が単純に保てる(任意式の対応は parser を肥大化させる)
- template と Ruby の分離が明確 = 教育コストが低い

### 3.4 トレードオフ

- 「テンプレで `@count + 1` と書きたい」場面でも `@count_plus_one = computed { @count.value + 1 }` と Ruby 側 ivar を増やす必要あり
- 派生 computed が多い form 等で **verbose** になる(これに対応するのが
  `data-field` compound directive のような対症療法)
- 利用者は最初に「式を書きたくなる」誘惑と戦う必要(教育)

---

## 4. Symbol leak 制約と Hash キー方針

### 4.1 判断

- **form field 名**: Symbol(source 静的、leak しない)
- **bind_list item Hash キー**: String 推奨(動的データ想定、Symbol leak 回避)
- **両者は別レイヤ** として共存

### 4.2 背景

mruby は **Symbol が GC されない**(intern table 永続)。動的生成した
Symbol が leak する制約がある。

歴史的に Lilac の bind_list items は String キー("`{"id" => 1}`")を
推奨してきた。一方 form gem は Symbol field 名(`f.field :email`)を採用。

### 4.3 判断の rationale

- form field 名は **source code に literal で書かれる**(`:email`)ので、
  intern される Symbol の集合は source の field 定義数で bounded → 安全
- bind_list items は **JSON / DOM 由来が多い**(`Lilac::JSON.parse` の返り
  値が String キー)→ 動的キー集合の可能性、Symbol leak リスク
- レイヤが違う = 慣行が違う、と spec で明文化(無理に一致させない)
- 将来 form nesting / array でも **flat path Symbol を作らない**(nested
  object 構造で表現)ことを spec 規約に組み込み、Symbol 安全を維持

### 4.4 トレードオフ

- 利用者は「form は Symbol、items は String」を覚える必要
- ただし HTML 側(`data-field="email"` / `data-key="id"`)は両方 String
  なので、template ベースで考えれば差を意識しない
- evaluator が両方を受け入れる lenient な lookup(Symbol → String
  fallback)で実装されており、ソース literal Hash で `{name: "x"}` と
  書いても動く(spec 上は String 推奨だが実装は寛容)

---

## 5. HTML helper / bind_list legacy mode の廃止

### 5.1 判断

`Lilac::HTML.tag` / `HTML(...)` / `HTML.safe_join` / `HTML.raw` /
`HTML::Safe` を廃止。`HTML.escape` のみ残す。bind_list の string モード
(block が String を返す)と managed template モード(`template:` kwarg)も
廃止。残るのは template node モード(`Template.new(node)`)のみ。

### 5.2 背景

旧設計には list 描画と HTML 構築で多数のモードがあった:

- bind_list 4 モード(string / managed-template / template-node / `template:` kwarg)
- HTML helper による builder DSL (`HTML(:li, "text", class: "x")`)
- `<template data-template="X">` の外部 template 仕組み

すべて「runtime canonical 化と data-each の inline body 機能」で **大部分が
data-each で代替可能** になった。

### 5.3 判断の rationale

- canonical を data-each に絞ることで mental model が単純化
- spec が短くなり、新規利用者が "どう書くか" を迷わない
- HTML helper を維持する保守コストが消える
- builder DSL の "code in template" 性質も Lilac philosophy と整合的でない

### 5.4 トレードオフ

- **明確な breaking change**(旧コードは動かなくなる、Phase D で削除予定)
- 既存 example の全面書き直しが必要(todo, kanban, receipt, multipage 等)
- 「真に動的な markup 生成」escape hatch として template node モードのみ
  残るが、これは advanced 用途で日常的ではない
- HTML.escape は残るので innerHTML XSS 対策は維持

---

## 6. CLI と runtime の lint severity 整合

### 6.1 判断

- **runtime が raise する違反は build 時も error**(例: undeclared
  `data-button`、directive 文法エラー、banned `data-attr-X` 属性)
- **runtime が warn / auto-recover する違反は build 時も warning**
  (例: undeclared `data-field` は runtime で auto-register、undeclared
  `data-form` は auto-create、form gem 未ロード時の `data-field` は silent
  skip — いずれも warning)

判断のキーは「runtime がエラーで止まるかどうか」。runtime が auto-X で
recover する違反を build error にすると、書いた通り動く HTML が build を
通らなくなり原則から外れる。

### 6.2 背景

旧設計では「CLI lint は warning、runtime は raise」のような **severity
gap** が発生しがちだった。build が通っても deploy 後即死する状況が
起きうる。

### 6.3 判断の rationale

- build 時に検出できる correctness violation を warning に留める理由はない
  (build error にしないと意味がない)
- severity が一致しないと「lint は通ったのに本番で raise」がデバッグ困難
- runtime severity policy を canonical として、CLI lint がそれに従う

### 6.4 トレードオフ

- CLI のエラー数が増える(意図的)
- 段階的移行(deprecated → warning → error)の余地は残す(個別 issue)

### 6.5 ステータス

2026-05-18 時点で実装完了。`CrossRefLinter` が form / field / button の
cross-reference を check し、`data-button="X"` で `f.button :X` 未宣言の
場合は **build error** (runtime raise との severity 一致)、`data-field` /
`data-form` 未宣言は warning (runtime auto-register / auto-create に
合わせる)。詳細は `lilac-form-spec.md` §13。

---

## 7. `<input value>` からの auto-register

### 7.1 判断

`<input data-field="X">` を scanner が発見し、対応 form に `:X` field が
**未宣言** の場合、HTML から **auto-register** する:

- **type**: `<input type="checkbox">` なら `:checkbox`、他はすべて `:text`
- **initial**: HTML の `value` 属性のみ参照(checkbox の `checked` 属性、
  textarea の textContent、select の selected option 等は **無視**)
- **validator**: 無し(常に valid)

Ruby で `f.field :X` が宣言されていればそれが優先(scanner は touchしない)。

### 7.2 背景

「input は form 経由が canonical」(§2)に決めた上で、単発 input
(検索ボックス、トグル、ステッパー等)も常に `form.field :query, initial: ""`
の 1 行を書く必要があった。検索ボックス 1 個のために form + field 宣言は
重く感じる場面が多い。

### 7.3 判断の rationale

- **「単純な field は HTML だけで完結」** が単発 input の ergonomics を
  大幅改善
- HTML5 標準の `<input value="">` を活かす(独自 `data-initial` を増やさず
  既存 attribute を尊重)
- **validator は Ruby 専管**(custom logic は HTML に持ち込まない、§2.2
  "Templates are configuration, not code" 原則を維持)
- type 判定は **checkbox のみ scanner で識別**(他は全部 `:text` で
  bind_input は `:value` プロパティ、Lilac 内部で区別する意味が無い)
- value 属性以外の初期値情報(checkbox の `checked`、select の selected
  等)を読まない選択 = spec が小さく、利用者の覚える規約が単純

### 7.4 トレードオフ

- **field 一覧の implicit 性**: Ruby を見ても全 field が分からない(HTML
  にも data-field がある)。dev_mode warning と CLI lint warning で typo
  検出は緩和するが、源泉が分散する事実は残る
- **checkbox の initial=true を表現するには Ruby 必須**(`checked` 属性
  は無視するため):
  ```ruby
  form.field :agree, type: :checkbox, initial: true
  ```
  HTML だけで完結したいケースで checkbox initial=true を表現できないのは
  小さな摩擦
- **旧 spec の "type は Ruby で明示" 方針を覆す**: form-spec §11.3.1 で
  checkbox のみ HTML から auto-detect する変更が要る(他の type は引き続き
  Ruby で明示、form-spec §11.7)
- **dev_mode warning が頻発**:auto-register を意図的に多用するアプリで
  warning が騒がしくなる可能性。CLI lint は build warning として残す

### 7.5 ステータス

実装済み。spec は本 §7 と form-spec §5 / §11.3 / §11.3.1 / §11.7 / §14 に反映。

---

## 8. form scope の決定規則

### 8.1 判断

form scope は **自 component subtree 内の ancestor `<form>` 要素** で
決まる:

| 構成 | scope |
|---|---|
| `<form data-form="signup">` あり | `:signup` named scope |
| 素の `<form>`(data-form 無し)あり | `:default` scope |
| `<form>` 要素無し、`<input data-field>` のみ | 自コンポーネントの default form |
| `<div data-form="X">` 等の非-form 要素 | `Lilac::Error` raise |
| 同 component 内に素の `<form>` 複数 | `:default` 衝突で raise |

ancestor walk は **自 component subtree 内のみ**(component 境界で停止、
他コンポーネントの subtree は scan しない)。form は常に自 component に
所有される(host の曖昧さなし、orphan signal なし、grep で field の
所在が完全に追える)。

form の Ruby 宣言(`form do |f| ... end`)が無くても、scanner が auto-create
するので「Ruby ゼロ宣言 + HTML だけ」のコンポーネントが成立する。

### 8.2 背景

form 抽象を導入する以上、「どの form にこの field が属するか」を答える
必要がある。素朴な選択肢:
- HTML native の `<form>` を尊重する → submit/validation の native 機能と整合
- 任意の要素で scope を作れるようにする → 柔軟だが意味が曖昧
- DOM 全体を walk して `<form>` を探す → encapsulation を破壊

### 8.3 判断の rationale

- **`<form>` 要素を基準にする**: HTML living standard と整合、`<button type="submit">`
  の native submit が直接 wire できる、`form=""` 属性(HTML 既定の form
  association)との semantic 衝突がない
- **subtree-only walk**: component encapsulation を維持(Lilac の他 directive
  `data-text` 等も自 component scope で `@ivar` を解決するのと整合)。
  cross-component sharing が必要なら §10 の `source:` パターンで明示橋渡し
- **非-form 要素を禁止**: scope の意味を曖昧にしない。submit を発火させ
  たくないだけなら `:submit` handler を書かなければ良いので非-form scope を
  作る実益が薄い
- **素の `<form>` 多重時 raise**: silent fallback よりも明示的なエラーで
  typo / 設計ミスを検出。明示的に区別したい場合は `data-form="..."` で命名

### 8.4 トレードオフ

- cross-component で form を共有したいケースは spec 外(§10 の `source:`
  パターンで橋渡し)
- 同 component 内に純粋に「何も付けていない `<form>`」を 2 つ並べる書き方が
  できない(片方を `<form data-form="X">` にする必要)
- HTML だけ書くシンプル user は「`<form>` の中に input を入れる」HTML 知識が
  必要(ただしこれは HTML 標準そのものなので学習負担とは言いにくい)

### 8.5 ステータス

実装済み(scanner)。form-spec §11.2 / §11.2.1 / §18.4 に反映。

---

## 9. `<input form="...">` 属性の扱い

### 9.1 判断

`<input form="...">` 属性は Lilac scope 解決には **使わない**。検出時は
`Lilac.logger.warn` で 1 回警告して属性自体は無視(native browser 機能は
そのまま動く)。

### 9.2 背景

HTML living standard には `<input form="<form-id>">` で離れた `<form>` と
関連付ける機能がある(form owner = その id を持つ form)。Lilac の form
scope 規則を ancestor walk だけにすると、この HTML 標準機能との関係を
どう扱うか決める必要がある。

### 9.3 判断の rationale

- `form=""` を Lilac scope に使うと **document 任意位置から任意 form に
  書き込み可能** になり、§8 の subtree-only 原則と矛盾、component
  encapsulation を完全に破壊
- 入れ子コンポーネントで足りないケースは `source:` 経由の明示橋渡しで
  カバーできる(§10)
- warn を出すのは「ユーザが期待する Lilac 挙動と実際の挙動が違う」ことを
  早期に知らせるため
- 属性自体は browser に渡す(native form submit には参加させる)ので
  HTML 機能は壊さない

### 9.4 トレードオフ

- `form=""` で離れた要素を form に組み込む既存の HTML pattern は Lilac
  state には乗らない(native submit のみで処理される)
- ただし Lilac で同等のことをしたければ component を入れ子にして `source:`
  で橋渡しする方が encapsulation を維持できる

### 9.5 ステータス

実装済み。form-spec §11.2.2 に反映。

---

## 10. stateful 子 input component の form 組み込み

### 10.1 判断

typeahead / 日付ピッカー等の自前 internal state を持つ入力部品を form
field として組み込む規約:

- 子 component は `Lilac::FieldComponent` 基底クラスを継承
  (`attr_reader :value` / `initial_value` / `reset` を提供)
- 親 component は `f.field :name, source: refs.X.component` で組み込む
- `source:` は polymorphic: `FieldComponent` か生 Signal の両方を受ける
- `FieldComponent` の場合 `form.reset` が `source.reset` を自動呼び出し
- 生 Signal の場合は reset 伝播なし(field 宣言時 dev_mode warn)

### 10.2 背景

form scope を subtree-only に決めた結果(§8)、子 component の `data-field`
は親 form に登録できない。一方、stateful な入力部品(typeahead / 日付
ピッカー / リッチエディタ等)は再利用性と複雑度の観点で **component として
encapsulate したい**。「子 component が持つ state を親 form の field
として扱う」橋渡し機構が必要。

### 10.3 判断の rationale

- **encapsulation 保持**: 子 component は親 form を知らない
  (`FieldComponent` 自体が form を知らない)、親が wiring 責任を持つ
- **two-way 自然に成立**: parent の `form[:country].value = ...` 書き込みが
  child の `@value` signal に流れ、UI も自動更新(signal の reactivity)
- **JSX 系の Modular Forms (Solid) / Felte `bind:value` (Svelte) と
  同じ camp**: 明示データフロー派、現代的 fine-grained reactivity との整合
  (React Hook Form 風の DI/Context 派とは別路線)
- **polymorphic `source:`**: 基底クラス継承の有無に関わらず使える、API が
  1 つで済む
- **reset 伝播の自動化**: `FieldComponent` 基底を継承するだけで `form.reset`
  が動く、慣行が code 化される
- **子 component が form 外でも使える**: `useFormContext` 風の暗黙 DI と違い、
  子は form 依存を持たないので汎用 input としても再利用可能
- **`source:` という名前**: polymorphic 引数の語感が `value:` より自然
  (component を渡しても違和感がない)、`initial:` との直交が明確

### 10.4 トレードオフ

- 子 component に `FieldComponent` 継承を要求(mix-in module 案より制約が強い、
  ただし将来 mix-in も追加可能)
- `source:` が polymorphic(component / signal の 2 種類を判定)で内部実装が分岐
- `attr_reader :value` を持たない arbitrary な component を `source:` に
  渡すと duck-type で扱われる(`respond_to?(:reset)` 判定)、暗黙の規約
- 親に 1 行 wiring 文(`f.field :country, source: refs.X.component`)が増える。
  React Hook Form 風の DI と比較すると boilerplate がやや多い(ただし
  Solid / Svelte 流派は同等)

### 10.5 ステータス

実装済み。form-spec §3.1 / §5 / §7 / §18.2.1 / §18.6 に反映。

---

## 11. scanner one-pass + 2-phase processing

### 11.1 判断

scanner は DOM を **one-pass で走査** して全 directive を record list に
収集し、**data-field / data-button を先に処理してから他 directive を
処理** する(internal 2-phase processing)。

### 11.2 背景

`<input data-field="text">` が DOM 上で `<p data-text="@upper">`
(computed が `form[:text].value.upcase` を読む)より **後** に出現する
ケースがあり得る。DOM 順に逐次 wire する設計だと、`@upper` 評価時点で
`form[:text]` が未定義になり壊れる。DOM 順序に依存する仕様は壊れやすい。

### 11.3 判断の rationale

- **one-pass DOM walk**: O(N) を維持、two-pass DOM walk より約半分のコスト
- **2-phase processing**: field/button の確定を他 directive より先に行う
  ことで、DOM 順序非依存性を保証(利用者は「`<input>` が `<p data-text>`
  より前か後か」を気にしなくてよい)
- form の auto-create(§8)も phase 2 で発生するので「Ruby ゼロ宣言 +
  HTML だけ」のコンポーネントが成立する
- Phase 1 で record list を全部作るので、エラー(`data-form` を非-form に
  書く等)も走査中に全件検出して報告できる

### 11.4 トレードオフ

- record list を一時的に保持するメモリオーバーヘッド(directive 数オーダー)
- 走査と wiring の 2 ステップに分かれるので実装の mental model がやや複雑
  (spec doc で説明が必要)
- ただし利用者が「DOM 順序を気にしないで書ける」メリットは大きい

### 11.5 ステータス

実装済み。form-spec §18.4 に反映。

---

## 12. Props 機構の導入 (superseded in part by §14)

### 12.1 当時の判断 (P1)

`data-prop-*` 属性経由で component に declarative configuration を渡す
**props 機構** を Lilac に追加する:

- `prop :NAME, TYPE [, default: VALUE]` で component class が宣言
- `props.NAME` でアクセス(mount 時に固定された値)
- 対応 type は **String / Integer / Float / Boolean** の 4 つ
- attribute 名は kebab、Ruby 名は snake(`data-prop-max-length` → `props.max_length`)
- 必須 prop の attribute 無し → mount 時に error として通知
  (error_boundary / `Lilac.logger.error` 経由、page 全体は continue)
- 型変換失敗 → 同上(`Integer("abc")` 等)
- Boolean は **`"true"` / `"false"` + presence shortcut** を許容、`"yes"` /
  `"1"` / `"on"` 等も error として通知
- 未宣言 `data-prop-X` 属性は dev_mode で warn(typo 検出)
- Phase 1 は **read-once**(mount 時固定)、reactive props は将来検討

詳細は [`lilac-props-spec.md`](./lilac-props-spec.md)。

### 12.2 背景

Lilac component は現状 **「設定値を外部から渡す機構」が無い**。同じ component
class を異なる設定で複数 instance 化したい場合(例: LabeledInput を
email / password / phone 用に複数使う、Counter を初期値違いで配置)、
利用者は以下のいずれかを強いられていた:

- 設定値ごとに subclass を作る(冗長、再利用にならない)
- 親 component から `refs.X.component.foo = ...` で setup 後に書く(順序問題、
  encapsulation 違反気味)
- そもそも component にしない(markup 重複)

React / Vue / Solid 等の主要フレームワークは props を第一級に持つので、
この摩擦は無い。Lilac の他原則(HTML 内ロジック禁止、`data-*` ベース
declarative)と整合する形で props 機構を導入する必要があった。

### 12.3 判断の rationale

- **`data-prop-*` 属性ベース**: Lilac の他 directive と同じ流儀、HTML 標準に
  乗る、scanner が読みやすい
- **4 type に絞る**: HTML 属性値は文字列なので primitive のみで実用上ほぼ
  カバーできる。Hash / Array は複数の primitive prop に分解する慣行で対応
  (spec を小さく保つ)
- **`Integer(...)` / `Float(...)` 厳密変換**: `to_i` の silent fallback
  (`"5x"` → `5`)を避けて typo を検出。Lilac の他 directive と同じ
  fail-fast 方針
- **Boolean ハイブリッド規約**: HTML 標準の `<input disabled>` 慣行を尊重
  しつつ、`"yes"` / `"1"` 等の曖昧表現を禁止(明示的 truth value のみ)
- **`props.X` API**: Stimulus の `this.XValue` より短く Ruby 慣行に近い。
  `props` namespace で「外部入力」と読める、補助メソッドを足しやすい
- **必須 prop は default 無しで宣言**: silent 0/nil fallback よりエラーで
  検出する方が安全(Lilac の他 directive 同様、ergonomics は warn だが
  correctness は raise)
- **mount 時 read-once**: 実装単純、MutationObserver 不要、99% のユース
  ケースをカバー。reactive opt-in は将来追加可能
- **kebab → snake auto-convert**: HTML と Ruby の慣行の差を吸収、Rails
  / Stimulus と同じ流儀
- **form と独立**: props は declarative configuration、`source:` は reactive
  value flow、直交する concern を分けて設計

### 12.4 トレードオフ

- **HTML 属性数が増える**: 設定項目が多い component(`LabeledInput` で 4〜5 個)
  は HTML が長くなる(`data-prop-X="..."` が 4〜5 回繰り返し)。React の
  `<X a="..." b="..." />` より文字数は多い
- **Hash / Array 渡しが困難**: 複雑な config を渡したい component(例:
  table の column 定義)は props だけでは表現困難。将来 JSON parse 等を
  検討する余地あり
- **mount 後変化しない**: Phase 1 では reactive props 無し。動的に props を
  変えるユースケース(SPA の route 変更で設定が変わる等)は別途 signal
  経由で扱う必要
- **`Lilac::Boolean` sentinel module**: Ruby に組み込み Boolean class が
  無いので独自 sentinel を使う(`prop :x, Lilac::Boolean`)。利用者が
  「`Boolean` が無い」事実を覚える必要

### 12.5 ステータス

Phase P1 実装済み(`runtime/mruby-lilac/mrblib/lilac_props.rb`)。
その後の拡張(`@X` Signal auto-init、public reader、row reuse 時の
`update_prop`、値式サポート等)は §14 で判断を更新した。
reactive props (P3) / change callback (P4) は将来 phase、実需に応じて追加。
詳細は `docs/lilac-props-spec.md` 参照。

---

## 13. metaprogramming(`instance_variable_*` 等)を極力使わない

### 13.1 判断

`instance_variable_get` / `instance_variable_set` / `instance_eval` /
`class_eval` 等の reflection API は、**Lilac 全 gem を通じて極力使用しない**。
やむなく使う場合は **1 箇所に集約**(call site が散らからないようにする)。

現在の例外:
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_evaluator.rb`
  の `Evaluator#lookup_ivar` 1 箇所のみ `@host.instance_variable_get(value.ivar_sym)`
  を呼び出す。`@ivar` 形式の directive 値(`data-text="@count"` 等)を
  resolve する技術上の必然(後述 §13.3)

### 13.2 背景

`data-text="@count"` のような directive 値の `@ivar` 表現は、HTML 文字列
から runtime で動的に instance variable を解決する必要があり、Ruby の
標準的な方法は `instance_variable_get` のみ(`instance_eval` も同等の
reflection、回避不可)。

一方、Lilac は多くの箇所で reflection を使わずに済む設計を選択している:
- Signal / Computed は明示的な `.value` API(reflection なし)
- Form#field / Form#button は Hash 登録(reflection なし)
- Component の lifecycle hook は override + super(reflection なし)
- Lilac::Props は class-level `@prop_declarations` を method dispatch
  で walk(`instance_variable_get` を class に対して使わず、method 経由)

このため reflection の使用箇所を **明示的に決定として記録**し、新規追加時は
spec / review で必ず議論する習慣を作る。

### 13.3 判断の rationale

- **意図的に設計された情報隠蔽を破壊する**: クラスが `private` / instance
  variable / `attr_reader` 未公開等で **意図的に外部から隠している状態**
  に対し、reflection は「外から強引に触れる手段」を提供してしまう。
  `instance_variable_get(:@foo)` は `@foo` が public な API として宣言
  されていない事実を無視する。これにより:
  - クラスの内部実装(ivar 名、private method 名)が **暗黙の public API
    に格上げ**されてしまい、リファクタリングの際に「外から名前で叩いて
    いるコードがあるかもしれない」という不安が常に残る
  - クラスの設計者が「ここは public」「ここは隠す」と決めた境界が、
    reflection ユーザの便宜で **silently 上書き** される
  - encapsulation を前提にした recovery(将来の名前変更、内部構造変更)
    が困難になる
- **可読性**: `host.foo` より `host.instance_variable_get(:@foo)` は意図が読みにくい。
  reflection は「マジック」とみなされ、メンタルモデル化が難しい
- **型安全性 / 静的解析**: reflection 経由のアクセスは LSP / Sorbet 等の
  static tooling から見えない。grep / IDE の "Find Usages" にも引っかからない
- **mruby 互換性**: mruby の `mruby-metaprog` gem は default では含まれるが、
  ビルド variant で除外する可能性に備える(min variant の縮小余地)
- **Lilac の方針との整合**: directive 値の grammar は `@ivar` / `it.field` /
  method 名等の **bare identifier 限定**(§3 directive 文法厳格化)で、
  reflection は「ユーザに reflection を書かせない」設計を支えている。
  internal 実装も同じ規律で metaprog を控えるのが筋
- **集約による影響範囲の最小化**: 1 箇所に閉じ込めれば、将来 mruby 側で
  `instance_variable_*` が deprecate される / 別 API に置き換わる場合の
  修正コストが極小化

### 13.4 トレードオフ

- **`@ivar` directive 文法の維持コスト**: 完全に metaprog free にするには
  user-facing API の breaking change(`attr_reader` 必須化、名前付き signal
  登録、別 syntax 等)が必要で、現実的でない。1 箇所の reflection を許容
  することで `@ivar` の自然な書き心地を維持
- **layering の不完全さ**: directives gem 内に reflection が残る。core
  (mruby-lilac)からは消えているが「framework 全体として metaprog free」
  ではない
- **「ここだけ例外」の運用負担**: 新しい reflection が紛れ込んだ際に PR
  review / codereview スキルでの検出が必要

### 13.5 ステータス

確定済み。reflection の使用箇所は次に集約 (2026-05-18 時点):

| 場所 | 用途 | 種類 |
|---|---|---|
| `lilac_directives_evaluator.rb` `Evaluator#lookup_ivar` | `@ivar` directive 値の resolve | `instance_variable_get` |
| `lilac_component.rb` Component class method `prop` | prop accessor (`instance.X`) の auto-define | `define_method` |
| `lilac_component.rb` Component class method `prop` 内の生成 method | `@X` Signal を `.value` で返す | `instance_variable_get` |
| `lilac_component.rb` `Component#install_prop_ivars!` | `prop` の Signal を `@NAME` ivar に projection | `instance_variable_set` |
| `lilac_component.rb` `Component#update_prop` | parent → child の prop signal update (row reuse) | `instance_variable_get` |
| `lilac_component.rb` `Component#validate_prop_ivars_not_overwritten!` | setup での `@NAME =` reassign を identity 比較で検出 | `instance_variable_get` |
| `lilac_router.rb:142` | router DSL の `instance_eval(&block)` | `instance_eval` |

P2 で props 機構が `prop` = ivar 宣言 + auto-defined accessor + auto-init Signal
を兼ねるようになったため、Component 側の reflection 使用が増えた。すべて
**Component の lifecycle hook (`prepare_setup_phase` / `mount`) または `prop`
DSL の class context** に閉じている — user code が ivar 名で reflection を
書く必要はない。

新規に `instance_variable_*` / `instance_eval` / `class_eval` 等を追加する
PR は、本 § に追記または例外の正当化を spec で議論することを必須とする。

---

## 14. Props P2: `prop` の意味拡張(ivar 宣言 + accessor + 値式)

### 14.1 判断

`prop :X, Type` の意味を、P1 の「値を `props.X` で読める static configuration」
から、次の 4 機能を一つの DSL で束ねる形に拡張する:

1. **`@X` Signal ivar の auto-init**(mount 時に `Signal.new(coerced_value)` を
   生成して `@X` に set。template から `@X` で直接参照可能)
2. **同名 public reader の auto-define**(`instance.X` で `@X.value` を返す
   accessor を `define_method` で生成)
3. **`data-prop-X` 値式の解決**(`data-prop-x="it.field"` / `data-prop-x="@ivar"`
   を parent の per-row scanner が clone-time に評価し、scalar を child の
   属性に書き戻す)
4. **mount-time override 検出**(setup 内で `@X = signal(...)` 等の reassign
   が起きたら Signal identity 比較で raise)

P1 の `props.X` accessor も back-compat として残す(read-through で `@X.value`
を返す)。詳細は `docs/lilac-props-spec.md` §3〜§8、§10.5。

### 14.2 背景

P1 完了直後の `examples/runtime-only/lilac-todo.html` の修正で、`<ul data-each="@items">
<li data-component="TodoItem">` の **per-row component** パターンが必要に
なった。子の中で `data-text="it.title"` と書きたいが、これは directive scanner
の boundary 規則(data-component subtree を child の Scanner に任せる)と
衝突 — child は parent の iteration item を知らないので resolve できない。

複数の代替案を比較した結果:

- 案A: `it` を child に貫通させる Iteration registry → component 境界の暗黙
  leak が将来の reactive props と概念衝突 → 不採用
- 案B: 新 directive family `data-bind-X="title"` → directive surface 拡大、
  `bind` (imperative API) と語呂が混乱 → 不採用
- 案C: テンプレ専用 namespace `props.X` (`data-text="props.title"`) → template
  syntax に新 namespace 追加が必要 → 不採用
- 案D (採用): **`prop :X` 自体に「`@X` ivar 宣言」を兼ねさせる** → 新 syntax
  追加ゼロ、`@X` 一本で値が読める。React/Vue の prop passing と同じ explicit
  data flow

### 14.3 判断の rationale

- **概念面積最小**: 「`@x` は signal、`it` は最寄り data-each の item、
  `data-prop-x` は親→子の prop 値」という 3 軸が直交。template 側は `@x` を
  「自分の signal」と理解すれば足り、ivar/prop の区別を意識しなくて済む
- **template syntax 不変**: `data-text="@x"` の既存 syntax を維持。新
  directive family も namespace も増えない
- **setup ergonomics**: `@title = signal(props.title)` のような boilerplate
  が消える(prop が自動で signal を作る)
- **React/Vue 慣行との整合**: 親→子は explicit な prop 渡し、子の中で完結
  (`it` 貫通のような暗黙 leak なし)
- **P3 (parent signal pass-through) への path**: Signal がすでに存在するので、
  parent signal の変化を effect で child の Signal に流す追加実装が自然
- **row reuse の reactive 更新**: bind_list が同一 key の row を再利用する際、
  parent scanner が `child.update_prop(name, value)` で Signal を mutate →
  既存 effect / computed が再評価される
- **override の早期検出**: `prop :title` と `@title = signal(...)` を user が
  両方書いてしまうと parent → child の reactive link が切れる。Signal の
  object identity 比較で mount 時に raise し、ヒント付きの error message
  (`@title.value = ...` / `@upper = computed { ... }` / rename) で誘導

### 14.4 トレードオフ

- **metaprog の使用箇所増**(§13 に反映済み): `define_method` + `instance_variable_set/get/defined?` が Component lifecycle に追加 — ただし全て
  framework 側 (`prop` DSL と mount hook) に集約、user code は触れない
- **mount lifecycle に +2 step**: `install_prop_ivars!` (Props.build 直後) と
  `validate_prop_ivars_not_overwritten!` (setup 直後)。lifecycle 全体が
  begin/rescue 連発になりやすいので `run_lifecycle_step(label) { ... }` の
  helper に統合(実装は `runtime/mruby-lilac/mrblib/lilac_component.rb` の
  `mount` 経路)
- **`@X` の意味二重性**: `@X` は ivar (user 定義) または prop (`prop :X` で
  auto-init) のいずれか。同名衝突は override 検出で raise されるので「両方
  存在する」状態は発生しないが、新規読者は「`@title` の出所」を判別するため
  に `prop :title` 宣言と setup を両方見る必要
- **value 式の制約**: `data-prop-x="@ivar"` は parent の setup より先に child
  の Props.build が走る case (non-data-each 配下) では `@ivar` 未定義時点で
  evaluate される → 現状未サポート(P3 候補)。`it.field` は data-each 配下
  のみで動く
- **CLI codegen 経路では `data-prop-X` の値式は未対応**: runtime canonical 経路
  のみで動く。CLI を経由したビルドは当面 lint で warn する必要(別 PR)

### 14.5 ステータス

確定・実装済み(2026-05-18 完了)。実装は以下:

- `runtime/mruby-lilac/mrblib/lilac_props.rb` — `Props.build` (Signal 生成のみ、
  host への書き込みなし)、`Props.coerce` 公開、read-through accessor
- `runtime/mruby-lilac/mrblib/lilac_component.rb` — `prop` DSL 拡張、
  `install_prop_ivars!` / `update_prop` / `validate_prop_ivars_not_overwritten!`、
  `defer_until_bound` / `each_binding_for` / `run_lifecycle_step` / `flush_deferred_until_bound!`、`component_for`
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` — `data-prop-*` の `resolve_props`、`extract_row_prop_exprs` / `push_prop_updates`、Component への `register_each_binding` 通知
- `runtime/mruby-lilac/mrblib/lilac_sortable.rb` — `make_sortable(by:)` 多態化、`sortable_target` 1 引数化 (registry 経由)

`examples/runtime-only/lilac-todo.html` / `examples/runtime-only/lilac-kanban.html` は新パターンを使う
形にリファクタ済み。P3 (parent signal pass-through) は `docs/lilac-props-spec.md`
§11 で記録、実需待ち。

---

## 15. lilac-full の bundle size 最適化(browser-only 化 + explicit allow-list + -Oz)

### 15.1 判断

`build_config/lilac-full.rb` を以下の方針で最適化する:

1. **gembox 不使用、explicit allow-list 方式**: `default-no-stdio` gembox の
   暗黙取り込みをやめ、Lilac が実際に使う gem だけを 1 個ずつ `conf.gem`
   で列挙
2. **browser variant では `mruby-io` / `hal-wasi-io` / `mruby-wasi-dir` /
   `mruby-wasi-env` を含めない**(File / Dir / ENV / STDERR は browser で
   不要)
3. **`-Os` → `-Oz`**(compile time)。`-flto` は採用しない(LTO + sjlj の
   code-gen bug を回避)
4. **Logger の default emit 経路を `STDERR.puts` から `JS.global[:console].
   call(:warn/:error, ...)` に変更**(2 の前提条件)

### 15.2 背景

`lilac-full.release.wasm` の baseline は ~1,035 KB raw / 322 KB brotli。
JS framework(React+ReactDOM ~140 KB brotli、Vue ~60 KB、Solid ~7 KB)
と比べて重く、production 配信での bandwidth / parse cost が懸念。

bundle 内訳を `wasm-objdump -h` と `.o` / `.mrb` artifact 集計で測ったところ:

- mruby VM + stdlib: 約 70%
- mruby-wasm-js bridge: 約 10%
- mruby-regexp-compat: 約 10%
- Lilac gems(core / directives / form / router / async): 約 10%

stdlib 内では `mruby-math` / `mruby-rational` / `mruby-complex` / `mruby-
bigint` / `mruby-time` / `mruby-random` / `mruby-set` / `mruby-objectspace`
等が Lilac から **grep で使用箇所 0 hit**。`mruby-io` も `STDERR.puts` 1 箇所
を除いて未使用 — その 1 箇所も browser には `STDERR` 自体が存在しない。

`-flto` は `lilac-compiled` では効くが、`lilac-full` に含まれる `mruby-
compiler` / `mruby-eval` 由来の setjmp/longjmp 経路で LTO + `-mllvm
-wasm-enable-sjlj` lowering pass が code-gen bug を起こし、生成 wasm が
`LinkError: env.setjmp` または `WebAssembly.Exception` で instantiate 失敗。

### 15.3 判断の rationale

- gembox 暗黙取り込みは「使ってない gem も入る」を運用上気付きにくくする。
  explicit allow-list なら **追加した時に commit に載る**(decisions / spec
  と同じく可視化)
- browser variant の I/O / WASI 関連 gem は **存在自体が無意味**(`STDERR`
  も `File.open` も browser には無い)。Logger の出力先は `console.warn` /
  `console.error` が natural — JS bridge は既に Lilac 内で多用されており、
  追加の dependency にならない
- `-Oz` は `lilac-compiled` で既採用、production 安定性は確認済み。
  framework は interop crossing が支配的で CPU bound でないので `-Os` →
  `-Oz` の runtime cost はほぼ無視できる
- `-flto` は理論的にはさらに削減できるが、bug を回避する複雑な workaround
  (`-Wl,-mllvm,-wasm-enable-sjlj` 等)も runtime error を再発させた。
  原因は LTO codegen と sjlj lowering pass の相互作用と推定。**`lilac-
  compiled` だけ -flto、`lilac-full` は無し** という非対称を許容する

### 15.4 トレードオフ

- **明示列挙の保守コスト**: 新規利用者が「Hash#dig が使えない」「Set が無い」
  等で詰まる可能性。docs に「Lilac 同梱の Ruby stdlib subset」を明文化する
  必要(`docs/lilac-spec.md` に追記対象)
- **`-flto` 非採用による size の取りこぼし**: 推定 ~30-50 KB raw / ~10-20 KB
  brotli の potential 削減。LTO bug が将来 mruby / wasi-sdk のアップデート
  で解消されれば再評価
- **削除した gem の復活コスト**: 利用者の Ruby code が `Set` や `Time` を
  使い始めた場合、build_config に 1 行戻すだけだが、size 増分は把握済み
  (該当 gem の `.o` size を decision 内に参考値として記録した)

### 15.5 ステータス

確定・実装済み(2026-05-19 完了)。size 測定:

| stage | raw | brotli |
|---|---|---|
| baseline(gembox + `-Os`) | 1,035 KB | 322 KB |
| → explicit allow-list(stdlib trim、§15.1 の項目 1) | 887 KB | 272 KB |
| → mruby-io / WASI drop(項目 2 + 4) | 817 KB | 253 KB |
| → `-Oz` at link / compile(項目 3) | **773 KB** | **247 KB** |

**累積削減: raw −262 KB(−25.3%) / brotli −74 KB(−23.0%)**。
全 618 wasm_spec tests pass(無回帰)。

実装ファイル:
- `build_config/lilac-full.rb` — 全項目
- `Makefile` — `-Oz` を link 行にも適用
- `runtime/mruby-lilac/mrblib/lilac.rb` — Logger emit 経路を JS console に

`lilac-compiled` 側は既に同等の最適化(explicit list + `-Oz -flto`)が
入っていて、本判断は **lilac-full を lilac-compiled の polish レベルに
追従させた** 整理。

---

## 16. `it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill

決定日: 2026-05-19

### 問題

`it.path`(`data-text="it.title"` 等)は directive grammar の中で **唯一の
path 構文**(他は identifier-only)で、Section 3 の「HTML 内にコードを書
かない」原則と摩擦があった。Phase E までは migration 期間中 ItPath を
受理しつつ dev_mode で deprecation warn を出していたが、grammar を 1 つに
畳めるなら早く畳む方が良い。

### 決定

`it.path` 構文(legacy `Value::ItPath`)を **runtime / CLI 双方から完全削除**。
value-binding 系 directive(`data-text` / `data-show` / `data-hide` /
`data-attr-*` / `data-css-*` / `data-bind` / `data-class` の hash value /
`data-each` の collection)はすべて **`@ivar` または `bare_ident`** の二択。

- `it.title` → `title`(bare ident)
- `it` 単独 → 構文として消滅(iteration item 全体を渡したいケースは
  そもそも稀で、必要なら parent で computed/expose にまとめる)
- `data-prop-X="it.Y"` → child 側で `prop :Y` 宣言 + auto-fill 経由
  (§7.6, [`lilac-props-spec.md`](./lilac-props-spec.md))

### 影響

- grammar table から `it_path` の行が消え、すべての value-binding が
  identifier-only に統一
- `data-each` body 外で bare ident を書いた場合は **parse 成功するが
  silent skip**(item context が無いため bind 不能)
- `data-prop-*` の bare ident だけは **literal interpretation**(`data-prop-status="todo"` は文字列 "todo")。iteration item field を渡したい場合は
  prop 宣言 + auto-fill で書く
- example HTML(receipt / kanban / todo / search)はすべて bare ident に
  移行済み

### 反映先 spec

- `lilac-directive-spec.md` §3(grammar)、§5(directive table)、§6.2
  (data-bind)、§6.5(data-prop-*)
- `lilac-props-spec.md` §7.5(data-prop-X 解釈)、§7.6(auto-fill)
- `lilac-proposals.md` の "`it.path` 全廃" 提案 → 本 §16 として昇格(提案
  本文は本 §で要約、proposals 側は削除可)

### 実装

- runtime: `Value::ItPath` クラス削除、`Evaluator#read_raw` の分岐削減、
  Scanner `requires_item?` 簡略化(`Value::BareIdent` のみ)
- CLI: `DirectiveValue::ItPath` クラス削除、`CrossRefLinter` の
  `lint_it_outside_each` / `uses_it_path?` / `starts_with_it?` 削除
- test: `it.path` 形式の literal を含む wasm_spec / CLI test を bare ident
  形式に移行、deprecation warn を期待する test を削除

実装ファイル(主要):
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_value.rb`
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_evaluator.rb`
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb`
- `cli/lib/lilac/directives/value.rb` (§17 で `cli/lib/lilac/cli/directive_value.rb` から移動)
- `cli/lib/lilac/cli/cross_ref_linter.rb`

---

## 17. directive binding は codegen が canonical / scanner gem は grammar reference

決定日: 2026-05-19

### 問題

`:full` target と `:compiled` target で binding 経路の責務が曖昧だった。

- 元の設計(decisions §1)では runtime canonical を謳い、`mruby-lilac-directives`
  gem の `Scanner` が DOM walk で directive を解釈する想定だった
- ところが CLI codegen は `data-each` の row body を `<template
  data-template="lil-each-...">` に **抽出** する。同じ HTML を `:full` で
  runtime scanner に食わせると、空の `<li data-each>` を見て row template を
  recover できず `tagName of null` で落ちる(parity 検証で発覚)
- builder.rb は `:full` だけ `[user_script, generated]` の順で emit して
  いたが、`Lilac.start` の時点で `Lilac::Bindings::<Class>` モジュールが
  まだ未定義のため、結局 scanner fallback に落ちて上記の bug を踏む
- かつ `:full` でも codegen 生成コードを並走させていて、scanner と codegen
  の binding が二重発火しうる構造になっていた

scanner と codegen は同じ grammar を **2 言語実装** している状態で、
`it.path` 削除のような変更が両側に対称に出る。`Lilac::Directives::Value`
と `Lilac::CLI::DirectiveValue` が並存し、片方を直して片方を忘れる事故が
起きやすい(実例: §16 の作業中に CLI 側だけ regex anchor を変更して runtime
側と挙動が divergent になりかけた)。

### 決定

**binding 経路の canonical を codegen に統一**。scanner gem は「directive
grammar の reference 実装」「`codegen :off` モードの escape hatch」として
位置付ける。

具体的な変更は 2 軸:

#### A. binding canonical = codegen

- `:full` / `:compiled` 両 target で **codegen 生成コードを user_script
  より前** に置く(`[generated, user_script]`)
- 両 target とも `emit_include: false`(codegen は `Lilac::Bindings::<Class>`
  モジュールを定義するだけで、明示的な `<Class>.include` は emit しない)
- `Lilac::Component#bind_template_hook` が **on-demand で**
  `lookup_codegen_bindings` → `self.class.include(bindings_mod)` →
  re-dispatch する。`Lilac.start` 時点で bindings モジュールが在ること
  だけが必要で、explicit include の有無は問わない
- scanner gem は **`bind_template_hook` 既存実装が無い場合の fallback
  経路**(= `codegen :off` の escape hatch)としてのみ残る

#### B. directive grammar の SSOT 構造 (`Lilac::Directives::*`)

CLI 側の文法レイヤを `Lilac::CLI::*` から **`Lilac::Directives::*`** に
rename し、runtime 側と完全に同名にする。`diff(1)` で片方の編集忘れを
即発見できる構造に再編。

```
cli/lib/lilac/directives/                runtime/mruby-lilac-directives/mrblib/
  value.rb            ──── diff 0 ────  lilac_directives_value.rb
  grammar.rb          ──── diff 0 ────  lilac_directives_grammar.rb
  class_parser.rb     ──── diff 0 ────  lilac_directives_class_parser.rb
  compat_rules.rb     ──── diff 0 ────  lilac_directives_compat_rules.rb
  compat.rb           ──── role-別 ──   lilac_directives_compat.rb
                                         (build-time raise vs runtime warn+skip)
  value_codegen.rb    ──── CLI のみ ──  (Value::Ivar / BareIdent を re-open し emit helper を追加)
  grammar_extra.rb    ──── CLI のみ ──  (class_name? / ref_ident? + INNER 定数)
```

運用ルール:

1. **diff-0 ペア**(`value.rb` / `grammar.rb` / `class_parser.rb` /
   `compat_rules.rb`)は本体を編集する PR で **両方を同時に同じ内容で
   更新する**。片側だけの修正は spec 違反とみなす
2. **role-別ペア**(`compat.rb`)は同じ `COLLISION_PAIRS`(= `compat_rules.rb`
   の SSOT)を consume するが、上位ロジックは別実装で構わない。`COLLISION_PAIRS`
   に行を足したら両 logic がそれを拾うことを test で確認
3. **CLI 専用 extra**(`value_codegen.rb` / `grammar_extra.rb`)は
   build-time にしか意味がないコード(emit helper / 静的検証 predicate)
   を re-open で追加する。runtime に伝播させてはいけない
4. `require_relative` は **個別の `directives/*.rb` 内に置かない**(runtime
   側は mrbgem の concat ロードなので require が無く、CLI と diff を取る
   際のノイズになる)。`cli/lib/lilac/directives.rb`(loader)に集約し、
   各 caller(`codegen.rb` / `cross_ref_linter.rb`)が
   `require_relative "../directives"` で束ねを引き込む

#### scanner gem の役割整理

`mruby-lilac-directives` gem は廃止しない。役割を再定義:

- **directive grammar の参照実装**: `Value` / `Grammar` / `ClassParser` /
  `Compat` の挙動定義として canonical。spec doc から疑問が出たときに
  「コードがどう書かれているか」を見に行く先
- **`codegen :off` モードの escape hatch**: CLI を介さず `<script
  type="text/ruby">` 直書きで Lilac を試したいケース(prototype /
  教育用デモ / オフライン HTML)で、runtime scanner だけで動かす経路を
  維持
- **bundle 影響**: scanner gem を `:full` から外せば数十 KB 削れる
  余地があるが、上記 2 用途のために残す判断。将来 bundle 圧縮の
  要件が出てきたら再評価

decisions §1 の「runtime canonical」記述は本 §17 で「**binding 経路は
codegen が canonical / grammar 解釈の参照実装は scanner**」に読み替える。

### 影響

- `:full` target で data-each を含む component が parity-runner で
  正しく動く(`tagName of null` バグ解消)
- 「片方だけ修正した PR」が `diff(1)` で機械的に発見できる
- `Lilac::CLI::DirectiveValue` などの旧名は完全消滅(CLI 内部参照は
  すべて `Lilac::Directives::*` に置換)
- 残る duplicate は本質的に同じ実装で、変更コストは 2x のままだが、
  片方の漏れは即検出される(従来は気付かないままズレるリスクがあった)

### 反映先 spec

- 本 § 自体が SSOT。`lilac-directive-spec.md` への明示的反映は不要
  (grammar 仕様自体は不変、実装構造の話)
- 命名・ファイル構造は実装ファイル(`cli/lib/lilac/directives/` 配下、
  `runtime/mruby-lilac-directives/mrblib/` 配下)が SSOT

### 実装

- `cli/lib/lilac/cli/builder.rb`: concat order を `[generated,
  user_script]` に統一、`emit_include: false`
- `runtime/mruby-lilac/mrblib/lilac_component.rb`:
  `lookup_codegen_bindings` + 再 dispatch で on-demand include
- `runtime/mruby-lilac/mrblib/lilac_ref.rb`: `Refs#collect` /
  `TemplateRefs#[]` が root 要素の `data-ref` も拾うよう拡張
  (codegen 一本化に伴い template root に data-ref が乗るケース対応)
- `cli/lib/lilac/directives/*.rb` 新設、`Lilac::CLI::*` から rename
- `cli/lib/lilac/directives.rb` (loader)
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_compat_rules.rb`
  新設(`COLLISION_PAIRS` SSOT)
- `test/parity-runner.mjs` + `test/parity-fixtures/`: `:full` と
  `:compiled` で DOM が一致することを継続的に検証

---

## 18. `lilac build --target compiled` は単一コマンドで deploy 可能な dist を産む

決定日: 2026-05-20

### 問題

`--target compiled` は decisions §17(codegen canonical 化)で `:full` と
DOM 一致するまで仕上がっていたが、**dist が deploy 可能でない** という穴が
2 つあった。

1. **page-inline `<script type="text/ruby">` が silent に dropped される**:
   builder は `.lil` component の script だけを `mrbc` で bytecode 化する。
   `pages/*.html` に直書きされた `<script type="text/ruby">` は extract も
   strip もされず、生 HTML のまま dist に出る。`lilac-compiled.wasm` は
   parser を持たないので **その inline source は実行されず、エラーも出ない**。
   `examples/7guis/` の 5 demo は全て page-inline 方式で書かれており、
   compiled build しても 1 つも動かないという「成功扱いの完全 broken」状態
   だった
2. **`vendor/lilac-compiled/` を populate する経路が無い**: builder の
   bootstrap module は `./vendor/lilac-compiled/index.js` を import するが、
   そこを埋める手段は `public/vendor/lilac-compiled/` への手動 cp 以外
   存在しなかった。さらに、`npm/lilac-compiled/index.js` は `import
   { createVM } from "@takahashim/mruby-wasm-js"` という **bare import**
   を持っており、bundler 無しの project ではブラウザが specifier を resolve
   できず 404 を出す。`runtime-only/` を捨てて `with-cli` 移行を勧める
   doc 体系で「CLI 使う方が壊れる」のは整合性が破綻する

「`lilac build --target compiled` を 1 回叩けば deploy 可能な dist が出る」
ことを compiled target の goal とする(`:full` は元から「open the HTML
file in a browser」で動くので、対称性として `:compiled` も箱で動くべき)。

### 決定

CLI が **runtime provisioning の責務を負う**。具体的には 3 軸の変更を入れる。

#### A. Page-inline `<script type="text/ruby">` を bundle + codegen に取り込む

新規 `SFC.extract_inline_ruby_scripts(html)` で page HTML を linear walk して
inline ruby ブロックを抽出。`Builder#build_page` で target に応じて分岐:

- `:compiled` — HTML から `<script type="text/ruby">…</script>` を **strip**
  し、抽出した source を当該 page の `ruby_source` 末尾(component scripts
  の後ろ)に append。content-hash が page 間で同じなら `.mrb` は 1 個に
  dedup される
- `:full` — HTML 内の inline script を **そのまま残す**。runtime parser の
  `vm.evalScript` が拾うので injection を二重化すると重複実行になる

加えて、page HTML に直書きされた `<X data-component="...">` 要素も .lil の
canonical コンポーネントと同じ扱いで **codegen にかける**。`Builder#scan_page_components`
が Nokogiri::HTML5 で fragment を walk し、`<lilac-component>` 由来でない
data-component 要素を **トップレベルも nested も** すべて拾う。各要素を
TemplateAST.parse → Codegen.generate にかけ、生成された `Lilac::Bindings::<Class>`
module を bundle 先頭側に同梱する。

nested data-component は **deep clone した上で内側の data-component の body を
strip** してから TemplateAST に渡す(これで `Crud` の bind_template_hook に
`CrudRow` のディレクティブが leak しない)。nested 自身も別途 codegen 対象に
なるので、`CrudRow` の bind_template_hook は別の module として emit される —
.lil で `crud.lil` + `crud-row.lil` が別ファイルになっていた場合の結果と等価。

compiled の bundle 構成順は `[.lil codegen → .lil user_script → page-inline
codegen → page-inline class 本体 → Lilac.start]`。`Lilac::Bindings::<Class>`
モジュールはユーザクラス定義より前にあるが、`Component#lookup_codegen_bindings`
は mount 時に名前で resolve するので順序は問題ない。

`Lilac.start` の末尾 append は本決定で導入された(compiled wasm は parser を
持たないため page-side で `vm.eval("Lilac.start")` できない — bytecode に
embed する必要がある)。pages-with-no-Ruby のケースだけは empty bundle で
.mrb も bootstrap も emit しない、という gate を維持。

#### B. Target-namespaced vendor layout

`public/vendor/` 直下を target ごとに分ける規約を確立:

- `vendor/lilac-full/`     — `lilac-full.wasm` + `mruby-wasm-js/` ブリッジ
- `vendor/lilac-compiled/` — `lilac.wasm` + `index.js` + `mruby-wasm-js/`

`Builder::EXCLUDED_DIRS_FOR_TARGET = { full: ["vendor/lilac-compiled"],
compiled: ["vendor/lilac-full"] }` で **inactive target の subdir を public
mirror から skip**。同じ project が dev=full / prod=compiled を両運用する
ケースで、両 target の asset を `public/` に並べたまま、dist では active
target 側だけが出るようになる。

#### C. CLI auto-vendor compiled runtime + inline boot module

`:compiled` build かつ実際に `.mrb` が emit されたとき、`Builder#auto_vendor_compiled_runtime!`
が `dist/vendor/lilac-compiled/` を **自動 populate** する:

1. `lilac.wasm` — binary copy
2. `mruby-wasm-js/*.js` — bridge ファイルを top-level だけ binary copy

そして **boot module は inline で render** する(`render_compiled_boot_module`):

```html
<script type="module" data-lilac-bootstrap>
  import { createVM } from "./vendor/lilac-compiled/mruby-wasm-js/index.js";
  const vm = await createVM({ wasm: "./vendor/lilac-compiled/lilac.wasm" });
  const bytecode = new Uint8Array(
    await (await fetch("./app.<hash>.mrb")).arrayBuffer()
  );
  vm.loadBytecode(bytecode);
</script>
```

これは `npm/lilac-compiled/index.js` の boot helper を **vendor しない** という
決定の現れ。npm の helper は bridge の API(`loadIrep` → `loadBytecode` rename 等)
や bare import (`@takahashim/mruby-wasm-js`) で history 上ドリフトしてきており、
CLI が rewrite/sync を続けるよりも、 boot 4 行を builder template として持つ方が
依存面積が小さい。`@takahashim/lilac-compiled` package は「CLI を使わない直接利用」
の道として独立に維持される。

加えて、**compiled の `ruby_source` 末尾に `Lilac.start` を append** する。compiled wasm は
parser を持たないため、page-side で `vm.eval("Lilac.start")` できない(=
bytecode に同梱されている必要がある)。page-inline / `.lil` の user code に
`Lilac.start` が書かれていなくても、builder が必ず最後に 1 行追加する(決定 A
の後段で述べた page-inline codegen と同様に、bundle 完成時に挿入される)。

各 source の **discovery 順**(`bytecode_builder.rb` の mrbc discovery と同じ
段階パターン):

| 段階 | wasm の source | bridge の source |
|---|---|---|
| 1 | `--lilac-compiled-path` CLI flag | `--mruby-wasm-js-path` CLI flag |
| 2 | `c.lilac_compiled_path` config | `c.mruby_wasm_js_path` config |
| 3 | `LILAC_COMPILED_WASM` env | `MRUBY_WASM_JS_PATH` env |
| 4a | `<gem root>/../build/lilac-compiled.wasm`(monorepo dev build)| `<gem root>/../mrbgem/mruby-wasm-js/js/`(monorepo)|
| 4b | `<gem root>/../npm/lilac-compiled/lilac.wasm`(monorepo の最後の npm-pack 成果物)| — |
| 5 | `<project>/node_modules/@takahashim/lilac-compiled/lilac.wasm` | `<project>/node_modules/@takahashim/mruby-wasm-js/` |
| 6 | — | `<project>/node_modules/@takahashim/lilac-compiled/node_modules/@takahashim/mruby-wasm-js/`(nested fallback)|

monorepo の wasm 検出が **build/ 優先 → npm/ fallback** なのは、`npm/lilac-compiled/lilac.wasm`
が `-flto` 入りで build された時代の成果物を carry しており、`env.setjmp` / `env.longjmp`
の未解決 import を残してブラウザ instantiation 時に `LinkError: function import requires
a callable` で落ちるケースがあるため。現 `build_config/lilac-compiled.rb` は `-flto`
を外しており、`make lilac-compiled` で作る `build/lilac-compiled.wasm` は env import を
持たない(= 現 bridge と整合する)。

boot helper は npm package の `index.js` を vendor せず、builder template として
`render_compiled_boot_module` で inline 出力する(上記決定 C 参照)ので、boot helper
の discovery 経路は不要。

全段失敗時は **build error**(具体的な fix 案 4 つを表示)。silent 失敗は
させない — `mrbc not found` と同じ severity。

### 影響

- `examples/7guis/` を例にすると、`lilac build --target compiled` → `dist/`
  に **6 HTML + 6 per-page `.mrb`(content-hash dedup)+ vendor/lilac-compiled/
  一式** が出て、`python3 -m http.server --directory dist` で 5 demo が
  全部動く
- `public/vendor/lilac-compiled/` への手動 cp 指示が完全廃止 — 新 project は
  `npm install @takahashim/lilac-compiled` だけで OK(monorepo 開発時は env も
  config も不要)
- target=full の出力バイト列は完全不変(inline extraction を skip、auto-vendor
  を skip)。後方互換 100%
- `:compiled` の auto-vendor 仕組みは **`:full` 側にも同じ規約を後付けで
  適用しやすい** — 別 PR で対称化予定(本 §18 では scope 外)

### 反映先 spec

- 本 § が SSOT
- `docs/lilac-workflow.md` の "target ごとの vendor 配置と自動 prune" 節
  (target-aware exclusion 部分)を更新済み。auto-vendor の振る舞いは
  CLI README (`cli/lib/lilac/cli/templates/README.md`)に転記
- `cli/lib/lilac/cli/compiled_runtime_resolver.rb` の class doc が
  discovery 経路の実装上 SSOT

### 実装

- `cli/lib/lilac/cli/sfc.rb`: `extract_inline_ruby_scripts` 追加(public API)
- `cli/lib/lilac/cli/builder.rb`:
  - `build_page` で inline 抽出 + target=compiled で strip
  - `scan_page_components` 新設(Nokogiri::HTML5 で page HTML を walk、
    nested data-component も収集、各々を TemplateAST + Codegen にかける)
  - `build_injection` に `page_inline_scripts:` / `page_components:` /
    `page_path:` キーワード追加。生成された Bindings module + 同梱の
    synthetic templates(data-each row 用)を injection に乗せる
  - `render_compiled_boot_module` を rewrite — npm 配布版 `index.js` への
    import を捨てて、bridge を直接呼ぶ self-contained module を emit
  - `auto_vendor_compiled_runtime!` 新設、`build` 後段で target=compiled かつ
    `.mrb` 存在時のみ呼ぶ(wasm + bridge を copy、`index.js` は inline emit
    のため不要)
  - `:compiled` の bundle 末尾に `Lilac.start` を自動 append
  - `EXCLUDED_DIRS_FOR_TARGET`(target-namespaced public mirror)
- `cli/lib/lilac/cli/compiled_runtime_resolver.rb` 新規: 6 段階 discovery を
  `bytecode_builder.rb` パターンで実装。monorepo 検出は gem の `__dir__` 4
  段親から(`File.expand_path("../../../..", __dir__)`)。monorepo の wasm 候補は
  `build/lilac-compiled.wasm`(`make lilac-compiled` 成果物)→ `npm/lilac-compiled/lilac.wasm`
  の順で、前者が古い `-flto` ビルドの env.setjmp 問題を踏まないようになっている。
  boot helper は wasm 検出と独立に走らせ、wasm 隣に index.js が無い構成(`build/` 配下)
  にも対応する。tests は `monorepo_root:` 注入で gem 位置に依存しない
- `cli/lib/lilac/cli/config.rb` + `config_loader.rb`: `lilac_compiled_path` /
  `mruby_wasm_js_path` を `Config` と `Settings` に追加
- `cli/lib/lilac/cli/command.rb`: `--lilac-compiled-path` / `--mruby-wasm-js-path`
  flag 追加、`Config.load` + `Builder.new` に pass-through
- `cli/lib/lilac/cli/dev_server.rb`: 同様の pass-through
- `cli/lib/lilac/cli/doctor.rb`: `RUNTIME_WASM` / `RUNTIME_JS_ADAPTER` の
  期待 path を namespaced layout に更新
- `cli/lib/lilac/cli/templates/{lilac.config.rb, pages/index.html, README.md}`:
  scaffold が namespaced layout + auto-vendor の前提で書かれるよう更新
- `cli/test/test_sfc.rb`(+5), `cli/test/test_builder.rb`(+9: target-aware
  exclusion 3 + inline 5 + auto-vendor 4 + 1 combine), `cli/test/test_compiled_runtime_resolver.rb`
  新規(12)。total 382 runs, 1051 assertions, all green

### 18.5 Refinement: `lilac build` の既定 target を `:compiled` に(2026-05-20)

§18 着地時は `lilac build` の既定 target が `:full` だった(`lilac dev` と
対称的に同じ default、user が production 用には `--target compiled` を
明示する設計)。しかし以下の理由で **既定を `:compiled` に変更**:

- `lilac build` の主用途は **production deploy**。production は基本
  `:compiled` の方が小さい bundle と faster boot を得られる
- `lilac dev` (既定 `:full`、mrbc 不要) と `lilac build` (既定 `:compiled`、
  mrbc 必要) で **Vite-style の dev/prod 二段構え** が明示的に成立する
- decisions §1 「ビルド不要で動くこと」の精神は `lilac dev` で保たれる
  (mrbc は依然 dev で不要)。`lilac build` だけが prod deploy 時の追加
  setup を要求するのは妥当

mrbc 不要で `lilac build` を回したい場合は `--target full` を明示する
escape hatch を残す。これは debug 用途 / mrbc セットアップが間に合わない
環境で有用。

#### 影響を受ける箇所

- `cli/lib/lilac/cli/config.rb`: `DEFAULT_BUILD_TARGET` を `:full` → `:compiled` に変更
- `cli/lib/lilac/cli/command.rb#print_next_steps`: `lilac new` の scaffold message に
  「ship 時は `lilac build`(compiled デフォルト)、mrbc-free が必要なら
  `--target full`」を追記
- `cli/lib/lilac/cli/templates/README.md`: scaffold README の build 例を更新
- `cli/README.md`, `docs/lilac-workflow.md`: build 既定の説明を更新
- `cli/test/test_command.rb`: 5 件の `lilac build` invocation に `--target full`
  を明示(mrbc-free のままテストを通すため)

CLI tests 393 all green、CLI 配下以外への影響なし。

---

## 19. Codegen positional `lilN`(`data-ref` 注入の廃止)

決定日: 2026-05-20

### 問題

§17 で codegen canonical を確立した直後、§18 で `lilac build --target
compiled` を「ノービルドで動く dist」まで仕上げようとしたところ、
page-inline `<X data-component="...">` をサポートする際に **`data-ref="lilN"`
の build-time 注入** が破綻した:

- `.lil` flow では template body は `.lil` 内で孤立した chunk → TemplateAST
  が Nokogiri で mutate(`data-ref` 付与)→ `<lilac-component>` 展開時に
  inline、で完結。page の outer HTML は不変
- page-inline flow では data-component subtree が page HTML 内に直接ある
  → refs を付与するには page HTML 全体を mutate して書き戻す必要があり、
  Nokogiri::HTML5.parse/fragment の round-trip が page の `<html>`/`<body>`/
  whitespace を正規化してしまい、ユーザの書いた page が build 後に
  byte-identical でなくなる

2026-05-20 の 7guis gallery で `Missing ref: lil0 in CounterTask` を踏み、
subtree mutation + string splice の力技も Nokogiri round-trip 経由で page
の outer 構造(`</body>` 消失等)を壊す経路に突入して、design レベルで
筋が悪いと判明した。

### 決定

**bind ID は build 時に発行しない — `refs.lilN` を runtime で positional
に解決する**。codegen の出力テキストは不変、HTML mutation だけ廃止する。

具体的には:

#### A. TemplateAST は HTML を mutate しない

- `assign_or_reuse_ref` の `elem["data-ref"] = candidate` を削除
- 同一 element の synthetic ref ID は **per-scope index**(`current_ref_scope.size`)
  に切り替え。ref_id "lil0" は「**この scope での 0 番目の directive-bearing
  element**」を意味する
- `current_ref_scope` には user-declared `data-ref` も登録される(scope 内
  ユニーク検査用)ので size は名前付き + 合成の合計を反映 — runtime も
  同じ規約で count する
- user-declared `data-ref="lilN"` は **build error**(`lilN` namespace は
  codegen 予約)

#### B. Runtime Refs / TemplateRefs は positional 解決

- 構築時に component 部分木を DFS preorder で walk
- `data-ref` 付き element → `@cache[name]` に登録(従来通り)
- directive-bearing element(`Lilac::Directives::Grammar::DIRECTIVE_ATTR`
  に match する `data-*` 属性を持つ)→ `@positional` 配列に追加
- `refs[X]` lookup: `@cache[X]` を優先、ヒットしなければ X が `lilN`
  形式なら `@positional[N]` にフォールバック、いずれも無ければ raise
- TemplateRefs(iteration row clone)は別 instance として同じ walk を
  row subtree に対して行う — `t.refs.lil0` は row clone の 0 番目を返す

#### C. compat check は (scope_id, ref_id) でグルーピング

build-time の `Lilac::Directives::Compat.check!` が directives を ref_id
で group_by していた箇所を `[scope_id, ref_id]` のタプルに変更。同じ
"lil0" が top-level scope と data-each iteration scope の両方に現れても
別グループとして扱う(両者は別 element)。

#### D. DIRECTIVE_ATTR の SSOT 拡張

`Lilac::Directives::Grammar::DIRECTIVE_ATTR` 正規表現を build-time
(`cli/lib/lilac/directives/grammar.rb`)と runtime
(`runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb`)で
diff-0 ペアとして追加。

`lilac-compiled` 変種は `mruby-lilac-directives` gem を含まないので、
`mruby-lilac` 側(`Refs::DIRECTIVE_ATTR_RE`)に **同じ regex を duplicate**
する。コメントで 3 ファイル間のペアリングを明示。

#### E. `<X data-field="...">` 内部 input への合成 `data-ref` だけ例外的に残す

`find_or_allocate_form_control_ref` は wrapper 要素 + 中の input という
組み合わせ専用の経路。input 本体は **directive-bearing ではない**(`data-*`
attribute を持たない)ので、runtime の positional walk では拾えない。
ここでは入力要素に `data-ref="lilN"` を mutation して名前付きとして登録
する(`@cache["lilN"]` で引ける)。これは局所的・既知の例外。

### 影響

- **page HTML が build 時 byte-for-byte 不変**: コメント・whitespace・
  attribute 順、すべて保存。「Lilac は HTML を foreign code に変質
  させない」原則と整合
- **page-inline data-component の codegen サポート**: §18 の
  `scan_page_components` で書いた Nokogiri 書き戻しロジックは廃止。
  代わりに `synthesize_page_inline_components` が page-inline subtree を
  in-memory `SFC::Component` として組み立て、`<lilac-component>` placeholder
  に置換するだけの軽量変換になる
- **dist HTML 軽量化**: 合成 `data-ref="lilN"` ノイズが消える
- **テスト追従**: `test_template_ast.rb` の synthetic ref-attribute assertion
  を反転(`refute_match(/data-ref="lil0"/`)。collision-skip テストは
  `lilN` namespace 予約テストに置き換え。runtime spec の "invalid data-ref
  name raises" は「missing template ref」に正規化
- **parity test**: `:full` / `:compiled` で DOM 一致を継続検証(変更後
  も全シナリオ pass)

### 反映先 spec

- 本 § が SSOT
- `cli/lib/lilac/directives/grammar.rb` と
  `runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb` に
  `DIRECTIVE_ATTR` 正規表現を追加(diff-0 ペア)
- `runtime/mruby-lilac/mrblib/lilac_ref.rb` に `Refs::DIRECTIVE_ATTR_RE`
  を duplicate(scanner gem を含まない `lilac-compiled` でも使えるよう)
- `decisions §17` の "codegen canonical" 方針は不変(本決定は内部表現
  の変更で、canonical の主体は引き続き codegen)
- `decisions §18` の `scan_page_components` 周り(Nokogiri 書き戻し力技)は
  本決定で不要になり、`synthesize_page_inline_components` に置換済み

### 実装

- `cli/lib/lilac/cli/template_ast.rb`:
  - `assign_or_reuse_ref` を per-scope counter + mutation 廃止に書き換え
  - `find_or_allocate_form_control_ref` を per-scope counter に揃え、
    `own_ref:` 引数経由で同一 input のケースを処理
  - `register_ref!` に `lilN` namespace 予約チェック追加
  - 直前 `find_or_allocate` が登録した synthetic と walker の elsif の
    重複登録を回避するガード
  - `@ref_counter` 廃止
- `cli/lib/lilac/cli/builder.rb`:
  - `synthesize_page_inline_components` 新設(page-inline data-component を
    in-memory `SFC::Component` 化 + `<lilac-component>` placeholder swap)
  - 旧 `scan_page_components` / `page_components` 引数 / Nokogiri 書き戻し
    ロジックを撤去
  - `build_injection` の signature を `page_inline_scripts:` のみに簡素化
- `cli/lib/lilac/directives/grammar.rb` + `runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb`:
  `DIRECTIVE_ATTR` regex + `directive_attribute?` 述語を追加(diff-0 ペア)
- `cli/lib/lilac/directives/compat.rb`: group_by を `[scope_id, ref_id]`
  タプルに変更
- `runtime/mruby-lilac/mrblib/lilac_ref.rb`:
  - `Refs` に `LILN_RE` / `DIRECTIVE_ATTR_RE` / `@positional` / `directive_bearing?`
    を追加。lookup に `lilN` positional fallback を生やす
  - `TemplateRefs` を querySelector ベースから positional walk ベースに
    書き換え(構築時に row clone を walk、cache + positional 両建て)
- tests 更新済み(`cli/test/test_template_ast.rb`, `cli/test/test_template_ast_form.rb`,
  `runtime/mruby-lilac/wasm_spec/test_template.rb`)。CLI test 382 runs all green、
  runtime wasm_spec 617 tests all green、parity-runner all scenarios pass

---

## 20. Component scope rule の確定 と `Lilac.start` 自動化

決定日: 2026-05-20

### 問題

§18(compiled target 統合)+ §19(positional `lilN`)の着地で Lilac の
component 定義場所が **3 つ** 並ぶ形に揃った:

1. `components/*.lil` — SFC 形式の単一ファイル component
2. page-inline `<X data-component="name">` — page HTML 中に直接書かれた
   component 要素(class 定義は同 page の `<script type="text/ruby">` 内)
3. page-inline `<script type="text/ruby">` — page HTML 中のロジック塊

しかしこの 3 階層は **scope rule が明文化されておらず**、silent failure を
許す状態だった:

- `.lil` の `Counter` と page-inline `<div data-component="counter">` が衝突
  しても `synthesize_page_inline_components` の `synthesized[name] = ...` が
  **無条件上書き** → user は `.lil` 側が使われていると誤認する
- 同 page 内で同名 page-inline component が複数あっても build error には
  ならず、最後の宣言が勝つ
- 別 page で同名 page-inline component を **別形** に書いても警告がなく、
  共有部品のつもりが page ごとに違う挙動になっていることに気付けない
- page-inline `<script type="text/ruby">` 内で `.lil` 由来 class と同名の
  class を定義しても Ruby 的には reopen として通り、build は成功するが
  挙動が壊れる

並行して **`Lilac.start` の責務分布が target 間で非対称** だった:

- target=full: user が `<script type="text/ruby">` に `Lilac.start` を書く
- target=compiled: builder が bundle 末尾に `Lilac.start` を自動 append

§18 が「同じ markup で両 target を切替可能」を目標にして着地した一方、
`Lilac.start` だけ user 責務が target に依存していて、これまで潰してきた
非対称性の最後の残滓になっていた。

Ruby の通常の常識(実行開始は明示)からは「`Lilac.start` を書かないで
済ませる」は素直ではない。これを framework 設計として正当化する位置づけが
必要だった。

### 決定

3 階層の scope rule を明文化 + build-time guard で衝突を潰す(A)、
`Lilac.start` を framework 内部の boot 呼び出しとして user 空間から外す(B)。

#### A. component scope rules (R1〜R4)

| 定義場所 | 名前空間 | 可視範囲 | 用途 |
|---|---|---|---|
| `components/*.lil` | **project-global** | どの page からも参照可 | 複数 page で共有する部品 |
| page-inline `<X data-component>` | **page-local** | その page 内 (nested 含む) のみ | その page 専用 compose 単位 |
| page-inline `<script type="text/ruby">` | **page-local 実行スコープ** | その page の `.mrb` 内 / `evalScript` 範囲 | その page の class 本体 / setup |

build-time guard(`cli/lib/lilac/cli/builder.rb`):

- **R1**: `.lil` と page-inline で **同名は build error**(silent override 禁止)。
  実装は `synthesize_page_inline_components` 冒頭で `lil_origin = components.keys.to_set`
  を捕捉、page-inline ループで `if lil_origin.include?(name)` なら raise
- **R2**: 同 page 内で同名 page-inline component の重複は **build error**。
  `seen_in_page = {}` を抱えて `if seen_in_page.key?(name)` なら raise
- **R3**: cross-page で同名 page-inline component が別形のとき **warning**。
  build 全体で `@page_inline_signatures = { name => [[content_hash, page_path], ...] }`
  を蓄積、終端 `warn_cross_page_signature_drift!` で同名異 hash を stderr 警告。
  シグネチャは whitespace 正規化後の SHA1 で比較
- **R4**: page-inline `<script type="text/ruby">` で定義する class 名が
  `.lil`-derived class 名と衝突したら **build error**。`ScriptAnalyzer.extract_top_level_class_names`
  で page-inline script 内の top-level class 名を Prism で抽出、`.lil` の
  `ComponentName.new(name).ruby_class` と突き合わせ。`check_class_name_collisions!`

R3 を error ではなく warning にしたのは、(a) 別 page で同名・同形を書く
ケース(分離 dist でも同じ button 部品など)を許容したい、(b) build を
止めるほどの実害はない(別 `.mrb` に閉じるので runtime 衝突は起きない)、
の 2 点。drift があった時に気付ければよく、強制ではない。

#### B. `Lilac.start` を framework 内部の boot 呼び出しに

##### B.1 設計の位置づけ — user 空間は宣言、framework が dispatch

user code を **procedural script ではなく declaration** として位置づける:

- user の Ruby = `class Counter < Lilac::Component` という **宣言**
- 「呼ぶ側」 = DOM 上の `<div data-component="counter">` という **dispatch
  指示**(DOM が dispatch table)
- dispatcher = framework 自身

Rails の `class PostsController < ApplicationController` の隣に
`rails server` を書かないのと同じ理屈で、Lilac でも `class Counter` の隣に
`Lilac.start` を書かない。`Lilac.start` は **framework internal な boot
呼び出し**で、user 空間ではない。

Ruby の明示性原則(`class Foo; end` は何もしない)と矛盾しないのは、
user 空間 = 宣言の集合 / framework 空間 = dispatch という責務分離が
成立しているため。

##### B.2 `Lilac::Registry#start` の idempotency

builder が自動 append する `Lilac.start` と user が明示的に書いた
`Lilac.start` が共存しても二重 mount しないことを保証する。

実装は **`start` 自体に explicit guard を追加するのではなく、内部 op が
すべて idempotent なので外側 guard は不要**(下記 caveat 参照):

- `install_observer` — `return if @observer` で 1 回しか install しない
- `prune_disconnected_components` — 切断済み component を消すだけ、二度
  実行で害なし
- `mount_subtree` — 各 element の `data-component-id` 属性を見て mount 済み
  なら skip(`existing_attr.js_null?` チェック)

**Caveat (2026-05-20 追記)**: 初版実装では explicit `@started` guard
(`return if @started; @started = true` + `reset!` で false 復帰)を入れて
いたが、これは runtime wasm test の `body[:innerHTML] = "..."; Lilac.start`
パターン(DOM を入れ替えた後の再 mount)を妨害してしまい test スイートを
壊した。internal ops が既に idempotent なので、explicit guard は redundant
かつ有害だった。よって `@started` guard は撤去し、idempotency は internal
ops の性質に委ねる形に修正した。

##### B.3 builder が target を問わず boot を auto-append

- target=compiled: 既存の bundle 末尾 `+ ["Lilac.start"]` を維持
  (`vm.loadBytecode` 完了 = 全 user Ruby 評価完了 = boot 発火)
- target=full: `bundle_scripts` の else 枝に `any_user_ruby ? scripts + ["Lilac.start"] : scripts`
  を追加。bridge JS の `querySelectorAll('script[type="text/ruby"]').forEach(...)` の
  eval loop が最後の injected block で `Lilac.start` まで到達する形

##### B.4 boot タイミングの spec

framework boot は **bootstrap module の eval loop 直後** で発火する。
「全 user Ruby 評価済み」は実行時に検出するのではなく、bootstrap module
上のコード位置として保証される:

- target=compiled: `vm.loadBytecode(bundle)` の直後
- target=full: bridge が `<script type="text/ruby">` を `evalScript` し終えた直後

これは framework が eval loop を所有しているため決定論的に確定する。
ES module script の暗黙 defer により、bootstrap が走り始める時点で既に
DOM 全体が parse 済 → `data-component` 要素も `text/ruby` 要素も全部
存在 → 明示的な `DOMContentLoaded` listener は不要。

##### B.5 position 依存性の境界(invariant)

builder emit / scaffold が bootstrap を **常に `<script type="module">` で
emit する** ことが invariant の前提:

| script 種別 | 位置依存性 |
|---|---|
| `<script type="module">` bootstrap | 非依存(暗黙 defer) |
| classic `<script src>` bootstrap | 依存(`<head>` だと壊れる) |
| `<script type="text/ruby">` user code | 非依存(browser が実行しない) |
| `.lil` ファイル | N/A(CLI が build 時に消費、browser に届かない) |

target=full の eval order は document order で、user の前方参照
(`class B < A` を `class A` より先に書くなど)には注意が必要だが、これは
browser の defer とは無関係の「Ruby の通常の load order」の問題。

#### C. 既存 example の `Lilac.start` 削除

`examples/7guis/public/boot.js` から明示的な `vm.eval("Lilac.start")` 行を
削除。boot.js は `querySelectorAll('script[type="text/ruby"]').forEach` の
eval loop だけを残し、loop の最後で builder が append した `Lilac.start` が
評価されて boot する形にした。

### 影響

- **scope の認知負荷**: 「どこに書いたら誰から見えるか」が表 1 つで説明
  できる状態。silent shadowing 事故が build error として検出される
- **target 切替の対称性**: user code は target を問わず同一(`Lilac.start`
  を書かない)。`lilac build --target full` と `--target compiled` を
  user code 無修正で切替可能(§18 と §1 の意図的な完成)
- **user code の宣言性**: class 定義 + DOM の data-* 属性だけで完結。
  procedural な entry point を含まない。Rails / Stimulus と同じ責務配分
- **既存 user code の互換**: idempotent (B.2) により `Lilac.start` を
  明示的に書いている既存 page もそのまま動く(builder の append が no-op に
  なる)。bridge JS から `vm.eval("Lilac.start")` を削除しても idempotent の
  おかげで safety net が残る
- **テスト**: builder spec に R1〜R4 collision case + auto-Lilac.start
  case を 8 件追加。total 390 runs all green
- **boot タイミングは仕様化された**: ES module deferral に依存することを
  明文化、bootstrap を classic script で書き換えると壊れることが明示的に
  guarantee の外と位置付けられる

### 反映先 spec

- 本 § が SSOT
- 実装は `cli/lib/lilac/cli/builder.rb`(R1〜R4 guard + auto boot inject)、
  `cli/lib/lilac/cli/script_analyzer.rb`(R4 用 `extract_top_level_class_names`)、
  `runtime/mruby-lilac/mrblib/lilac_registry.rb`(idempotent `start` + `reset!`)
- proposals.md からは該当節(「コンポーネント scope rule の確定と
  `Lilac.start` 自動化」)を削除
- `lilac-decisions.md §1`(runtime canonical / CLI optional)— B の boot
  統一は「target 切替が user code を変えない」原則の補完
- `lilac-decisions.md §18` — 本決定は §18 が露呈させた scope と boot の
  非対称性を解消する後続整備

### 実装

- `cli/lib/lilac/cli/builder.rb`:
  - `synthesize_page_inline_components` に R1 (lil_origin)、R2 (seen_in_page)
    の guard を追加。R3 の signature 記録もこのループ内
  - `build_page` で `check_class_name_collisions!` を `build_injection` 直前に
    呼び出す(R4)
  - 新 method: `check_class_name_collisions!`, `signature_for`,
    `warn_cross_page_signature_drift!`, `build_scope_error_message`
  - `@page_inline_signatures` ivar を `build` で初期化、`warn_cross_page_signature_drift!`
    を pages.each ループ後に呼ぶ
  - `bundle_scripts` で `any_user_ruby` の有無を見て full mode でも
    `+ ["Lilac.start"]` を append
- `cli/lib/lilac/cli/script_analyzer.rb`:
  - `extract_top_level_class_names` / `collect_top_level_class_names` を新設
    (Prism の `ClassNode#constant_path` から名前抽出)。nested class は
    対象外(top-level scope のみ)
- `runtime/mruby-lilac/mrblib/lilac_registry.rb`:
  - 当初は `@started` ivar + explicit guard を入れたが、internal ops
    (`install_observer` / `mount_subtree` / `prune_disconnected_components`)
    が既に idempotent であること、explicit guard が test の DOM 入れ替え
    パターンを妨害することから撤去(B.2 Caveat 参照)。実装としては
    現状 `start` に追加 guard なし
- `examples/7guis/public/boot.js`:
  - explicit `vm.eval("Lilac.start")` を削除、boot は builder の自動 append に
    委譲。idempotent guard が safety net として効くので bridge から消しても
    user が書いた既存 page は壊れない
- tests:
  - `cli/test/test_builder.rb` に §B (auto Lilac.start) と §A (R1〜R4) の 8 件
  - CLI test 390 runs, 1085 assertions, all green

### 20.6 Refinement: `Lilac.start` の責務を boot helper layer に統一(2026-05-20)

§20.B の初版は **builder が `Lilac.start` を auto-inject する** 実装で
着地したが、§1(Runtime canonical / CLI optional)との整合性レビューで
**「user が `Lilac.start` を書かない」規約が CLI 利用時にしか成立しない**
drift が見つかった:

- CLI target=compiled / target=full: builder が `Lilac.start` を append
- runtime-only HTML(`@takahashim/mruby-wasm-js` を直接 import する Pattern B): user が手書きで `Lilac.start` を call する必要

§1 の "CLI は optional な最適化レイヤ" 原則からすると、boot の framework
責務は CLI の特権機能ではなく、**Lilac-specific boot helper layer** に
属させるべき。

#### 再構成内容

`Lilac.start` の発火位置を builder から boot helper layer に移動:

- **target=compiled の `render_compiled_boot_module`**: 初版は
  `vm.loadBytecode(bytecode)` の直後で `vm.eval("Lilac.start")` を呼ぶ案
  だったが、**compiled 変種の wasm は `mruby-compiler` / `mruby-eval` を
  含まない** (build_config/lilac-compiled.rb 参照) ため、post-load の
  `vm.eval` で任意 Ruby ソースを評価できない。よって target=compiled では
  **builder が bundle bytecode 末尾に `Lilac.start` を append し、
  `loadBytecode` の top-level 実行で boot が走る** という形に揃える。
  inline boot module は `loadBytecode` だけを呼ぶ
- **target=full の Lilac-specific boot helper**(例: `examples/7guis/public/boot.js`):
  `document.querySelectorAll('script[type="text/ruby"]').forEach(eval)` の
  **直後** に `vm.eval("Lilac.start")` を呼ぶ。target=full は parser を持つので
  ここは runtime 側で発火
- **runtime-only path で `@takahashim/lilac-full` の `boot()` を使う場合**:
  将来 `boot()` 自体も eval 完了後に `Lilac.start` を呼ぶようにする(別 PR、
  本決定の対象外。idempotent guard があるので即時の修正は不要)
- **Pattern B(user が自前で createVM + vm.eval を組む runtime-only)**:
  user が `Lilac.start` を Ruby 側に書くか、自前 bridge wrapper の最後で
  `vm.eval("Lilac.start")` を呼ぶ。framework 側に責任は無い(自前 bridge を
  書く以上 boot 呼び出しも user 責務)

#### 影響

- **user code の対称性**: `lilac build --target full` / `--target compiled` /
  CLI を使わず `boot()` helper を import する runtime path、いずれも user は
  `Lilac.start` を書かない
- **builder の責務縮小**: full mode で `any_user_ruby ? scripts + ["Lilac.start"] : scripts`
  の特例処理が消える。compiled mode の bundle 末尾 append は parser 制約から
  維持(下記 caveat)
- **bytecode と boot helper の責務分担**: target=full は boot helper layer
  (JS) が boot を所有。target=compiled は parser 制約で「bundle 末尾の
  `Lilac.start` を builder が pre-compile」が依然必要 — boot helper layer の
  "boot 担当者" 役は inline boot module の `loadBytecode` 呼び出しが果たす形
  (bytecode を実行する = boot を実行する)
- **§1 整合**: "CLI は optional な最適化レイヤ" 原則がより純粋に成立。
  CLI を介さない runtime-only path でも(適切な boot helper を使う限り)
  user code が同じ形を保つ

#### 影響を受ける箇所

- `cli/lib/lilac/cli/builder.rb`:
  - full mode: `any_user_ruby ? scripts + ["Lilac.start"] : scripts` を
    `scripts` に戻す(boot は boot helper layer 側)
  - compiled mode: bundle 末尾の `+ ["Lilac.start"]` append は **維持**
    (parser 制約のため bytecode に embed する必要あり)
  - `render_compiled_boot_module` は `loadBytecode` だけを呼ぶ形に戻す
    (`vm.eval("Lilac.start")` は parser が無いため使えない)
- `examples/7guis/public/boot.js`:
  - eval loop 末尾に `vm.eval("Lilac.start");` を復活(§20.C の削除を
    取り消す形 — boot.js こそが boot helper layer の実体)
- `cli/test/test_builder.rb`:
  - `test_target_full_auto_appends_lilac_start` を `test_target_full_does_not_inject_lilac_start_into_script_block` にリネーム
    (アサーションを反転 — Lilac.start が **inject されない** ことを確認)
  - `test_target_compiled_bundle_includes_lilac_start` を
    `test_target_compiled_bundle_includes_lilac_start_in_bytecode` にリネーム
    (`.mrb` 内に Lilac / start sym が残ること + boot module が `vm.eval` を
    呼ばないことを確認 — parser 不在 caveat)
  - `test_target_full_no_lilac_start_when_page_has_no_ruby` を
    `test_target_full_pure_static_page_emits_no_script_block` にリネーム
    (Ruby 無しの場合は injection そのものが起きないことの確認)
- idempotent `Lilac::Registry#start`(§20.B.1)は据え置き — user が手書きで
  `Lilac.start` を書いた既存コードへの safety net として依然必要

CLI tests 390 runs, all green。examples/7guis の full / compiled 両 build も
確認済み:
- target=full の dist HTML に `Lilac.start` 無し、boot.js が eval loop 末尾で発火
- target=compiled の bundle bytecode に `Lilac.start` を builder が append、
  inline boot module は `loadBytecode` のみ呼んで boot が走る

**Caveat (2026-05-20 追記)**: 当初の refactor 案 (compiled 側でも boot module
内で `vm.eval("Lilac.start")`) は `lilac-compiled` wasm が `mruby-compiler` /
`mruby-eval` を含まない (build_config/lilac-compiled.rb で明示的に除外) ため
runtime error になることが `wsv dist` での動作確認で判明。target=compiled は
parser 制約により bundle 末尾 append の従来形が必須で、対称性は完全には
取れない。それでも target=full は boot helper layer (JS) で boot を fire し、
target=compiled は bytecode-embedded boot が走る、という二段は維持できる
(user 視点では「`Lilac.start` を書かない」契約は両 target で揃う)。

### 20.7 Boot pattern を上流選択として明文化 + Pattern A の 3 段グラデーション(2026-05-20)

§20.6 の boot helper layer 移譲を受けて、Lilac の運用設計の **上流判断** を
明文化する。これまで「単一 HTML か project 構造か」が user 側の最初の選択と
誤解されがちだったが、本質はそこではなく **boot pattern (A / B) の選択** が
最上位にあり、file 形式はその副産物。

#### Pattern A / B の定義

- **Pattern A**: Lilac-provided boot helper(npm `@takahashim/lilac-full` の
  `boot()` / CLI inline bootstrap module / scaffold `boot.js` 等)が bridge
  を所有。`createVM` → user Ruby eval → `Lilac.start` の一連を helper が回す。
  user 側は **class 定義 + DOM だけ** 書く
- **Pattern B**: user が自前 `<script type="module">` で `createVM` から書き、
  `Lilac.start` も Ruby 側に明示で書く。`examples/runtime-only/*.html` がこの
  形。bridge layer の細部(wasm memory introspection, callback handle 数の
  expose 等)に踏み込む題材に向く

runtime は両 pattern で共通(§1 canonical 不変)、変わるのは **JS-side glue
だけ**。

#### Pattern A の 3 段グラデーション

Pattern A の boot helper は **入手経路** で 3 段に分かれる。deployment intent
の順に低摩擦 → 高機能:

| 入手経路 | 例 | 向いている用途 |
|---|---|---|
| **CDN** | `import { boot } from "https://esm.sh/@takahashim/lilac-full"` | CodePen / 静的 host / 学習デモ / `<script>` タグ 2 つで動かせる最低摩擦パス |
| **npm install** | `import { boot } from "@takahashim/lilac-full"` | bundler / 自前 build pipeline 上で使う |
| **CLI `lilac build`** | builder が inline bootstrap (target=compiled) / scaffold `boot.js` (target=full) を emit | multi-page project + mrbc 経由の bundle size 最適化、project 構造前提 |

3 つとも boot helper layer の役割は同じ(`createVM` → script eval →
`Lilac.start`)。違うのは:

- **wasm の供給元**: CDN は package に同梱、npm はローカル `node_modules/`、
  CLI は `dist/vendor/lilac-compiled/` に CLI が auto-vendor
- **Ruby の供給形**: CDN / npm は inline `<script type="text/ruby">`、
  CLI target=compiled は `.mrb` bytecode
- **file 形式の前提**: CDN / npm は単一 HTML でも project でも可、CLI は
  project 構造を要求

#### File 形式は下流

```
deployment intent  →  boot pattern (A or B)  →  file layout
   (どう動かす?)        (誰がbridgeを持つ?)      (単一HTML / project)
```

「7guis 形式 (project 構造) で書けば CLI で動く」は **必要条件だが本質ではない**。
本質は Pattern A を採用すること。理論上は単一 HTML + Pattern A も可
(`<script type="module">import { boot } from "..."; boot();</script>` だけで
完結)、project 構造 + Pattern B も可(各 page に自前 bridge を書く)だが、
後者は CLI と相性が悪い(自前 bridge と CLI bootstrap が衝突する)。

#### 同一 file の dual-purpose は採らない

Pattern A と Pattern B が同じ HTML 内に共存すると以下の理由で破綻するため、
framework として dual-purpose 設計は採らない:

- `createVM` が 2 重に走り、wasm instance を 2 個立てる
- user 側 `<script type="module">` が `vm.evalScript("#ruby-source")` を呼ぶが、
  CLI compiled mode では既に script tag が strip されているため失敗
- Ruby 側で `JS.global[:__breakout_vm]` 経由で vm を取る pattern は、CLI 側
  の bootstrap が立てた別 vm を参照することになり整合性が崩れる

`examples/runtime-only/lilac-breakout.html` がまさにこのケースで、CLI に
そのまま通すと動かない。これは bug ではなく **設計上の境界**。CLI 化したい
場合は別 example として Pattern A 形式で書き直すのが筋。

#### 影響

- **doc clarity**: 「CLI を使うべきか」の判断は file 形式の好みではなく
  deployment intent から導かれる boot pattern 選択の問題、と明確化
- **runtime-only example の役割**: Pattern B を見せる教育的サンプルとして
  存続意義が明示される。CLI が動かない HTML があっても "bug" ではない
- **将来 examples**: CDN 経由 demo を `examples/cdn/` に追加する余地が
  生まれる(npm publish 後の follow-up)。Pattern A 最低摩擦パスの実例

#### 影響を受ける箇所

- `npm/lilac-full/index.js` の `boot()` を §20.6 に揃える(eval 末尾で
  `vm.eval("Lilac.start")`)。これで CDN / npm install 経由でも boot helper
  layer の責務契約が成立する
- `examples/runtime-only/lilac-breakout.html` 等は Pattern B のままで OK
  (CLI 化したい場合は別 example として作る)
- `lilac-design.md` / `lilac-spec.md` に Pattern A / B の区別を反映するのは
  follow-up(本決定は decisions.md 内に閉じる)

### 20.8 compiled mode でも `<script type="text/ruby">` を dist HTML に残す(2026-05-20)

§18 の初版実装では target=compiled の build で `<script type="text/ruby">`
要素を **dist HTML から strip** していた(`extract_inline_ruby_scripts` の
`stripped_html` 経路)。意図は「parser が無い compiled wasm では browser が
text/ruby を実行できないので残しても dead text、size 減らすために消そう」。

しかし以下の不利益が後から発覚:

- **source-display 系の introspection 機能が壊れる**: `examples/7guis` の
  `boot.js` は最初の `<script type="text/ruby">` を `<code id="source-display">`
  に mirror しているが、compiled では tag が消えているのでフォールバック
  placeholder("// Source is compiled into the .mrb bundle. Run the full target
  to see the original Ruby here.")を表示する分岐があった
- **target 間の HTML 非対称**: target=full / target=compiled で dist HTML の
  semantic が違う(同じ source から異なる HTML が出る)。"compiled は bytecode
  経由で動く版で、それ以外は同じ" という素直な理解が成立しない
- **view-source 体験**: compiled mode の page を開いた人が browser dev tools
  で view-source しても Ruby が見えない。Lilac の "Templates stay as valid
  HTML5 with `data-*` directives" / "Ruby + HTML を書いてブラウザで開く" 系の
  方針と整合しない

#### 決定

**両 target で `<script type="text/ruby">` を dist HTML に保持する**。
`extract_inline_ruby_scripts` は引き続き `.mrb` バンドル用にソース文字列を
抽出するが、HTML の strip は行わない。

target=compiled での挙動:

- browser は `text/ruby` を unknown type として実行スキップ(副作用なし)
- 同 page に並ぶ inline boot module は `loadBytecode` だけを呼ぶので script
  tag を読まない
- script tag は完全に dead text として残る。size 増は数 KB レベルで、HTML
  gzip / brotli で圧縮されればさらに小さい(`.mrb` の "parser を wasm から削る"
  価値は不変)

#### 影響

- `examples/7guis/public/boot.js` の compiled / full 分岐を統合: 両 target で
  同じ source-mirror 処理(`document.querySelector('script[type="text/ruby"]')`
  → `<code id="source-display">` にコピー)が動く
- target=full / target=compiled の dist HTML は **bootstrap module 部分以外
  bit-identical** に近づく(完全一致ではないが、user の書いた markup は同じ)
- 「production minify したい」需要は HTML minifier(htmlnano / html-minifier-terser
  等)を後段で挟む運用に委譲。CLI 側に `--strip-source` のような flag を入れる
  予定なし(判断責務を user に押し付けず、default は keep のみ)

#### 影響を受ける箇所

- `cli/lib/lilac/cli/builder.rb`:
  - `build_page` の `html = extracted[:stripped_html] if @target == :compiled`
    を削除(`extracted[:scripts]` の取得は維持)
  - 関連コメントを「strip 廃止、両 target で keep」に更新
- `examples/7guis/public/boot.js`:
  - compiled branch の placeholder フォールバックを削除、source-mirror を
    両 target 共通で実行する形に整理
- `cli/test/test_builder.rb`:
  - `test_target_compiled_includes_page_inline_ruby_in_mrb` を「`.mrb` には
    含まれる **AND** HTML にも script tag が残る」を確認する形に更新
- 7guis の dist を再 build して compiled mode で source-display が表示される
  ことを確認済み

---

## 21. `data-bind` の復活と form の "集約 layer" 化(§2 部分覆し)

決定日: 2026-05-19(scanner 実装 + 関連 spec 更新)/ 本決定の正式昇格は 2026-05-20

### 問題

§2 で「input/textarea/select の declarative bind は form 経由が canonical、
汎用 `data-value` / `data-checked` は廃止」と決めた。理由は「同じことをやる
2 directive を維持する mental cost」「form 経由なら validation / touched /
dirty / error が ついで に得られる」だった。

しかし運用してみると、**コレクションの 1 要素としての input** (receipt の
行内 input、todo の編集モード、テーブルセル inline 編集、検索ボックス、
toggle 等)で form 経由が unergonomic になることが分かった:

- 行ごとに `<form>` を入れるのは semantic に違和感 (submit も send button もない)
- かといって親 form に全行の field を register すると、field 名が動的
  (`qty_1`, `qty_2`, ...) になり Symbol leak 規約 (§4) と衝突
- 結局 `bind_input refs.X, @signal` の imperative escape hatch に逃げる
  しかなく、declarative-first の Lilac 方針 (design.md §2.1) と齟齬
- 「検索ボックスやトグルを form と呼ぶ違和感」が §2 のトレードオフ節で
  既に意識されていたが、運用上は単発 toggle 1 個でも form を立てる構造
  が強制されていた

receipt example の bind_list → data-each 化作業 (2026-05-18,
`examples/runtime-only/lilac-receipt.html`) で実際にこの摩擦が顕在化。
form-spec §2 「現時点で非対応 (将来検討): 動的 collection / field array」も
**この問題の自覚的な棚上げ** として記録されていた。

### 決定

現状の「form が field を所有、field が binding を持つ」という 2 層構造を、
**直交する 3 層**に再構成する:

```
signal     値そのもの (Signal / Computed)。§2 と無関係、変更なし
  ↓ orthogonal
binding    signal ↔ DOM input の sync 機構。`<input data-bind="@qty">`
           で declarative に書ける。form と無関係に成立
  ↓ optional aggregation
form       既存の binding 群を集めて validation / submit / reset /
           base_error を提供。binding の **集約 layer** であり、binding
           それ自体ではない
```

具体には:

- **`data-bind="@ivar"` directive を導入** (§2 で削除した `data-value` /
  `data-checked` のリバイバル + 統合版)。値は signal ivar のみ、input
  type に応じて value / checked / files 等を自動選択。form の有無は不問
- **既存の `<input data-field="qty">` は form scope 内 binding の
  short-hand として温存**。`f.field :qty, ref:, initial:` 宣言は
  「signal を作って binding を貼って form に登録」の 3 ステップを 1 行で
  やる便利 API という位置付けに
- **form gem 側の API 追加は不要**。`data-bind` で結線した signal を
  form の validation に乗せたい場合は、既存の `f.field :X, source: @X`
  (§10) がそのまま使える。3 経路 (`data-bind` 単独 / `f.field` +
  `data-field` / `f.field` + `source:`) で完全カバー、API surface 増加なし
- field array 問題は「field を `data-each` で動的に並べる」ではなく
  「各行を per-row 子 component で表現し、その component 内で `data-bind`
  + ローカル signal を持つ」として解決。さらに踏み込んで「item に Signal
  を nest して per-row component すら不要」という path は §16 の bare ident
  拡張で確定済み (`data-bind="qty"` で iteration item の Signal field を bind)

### 利用者の判断基準

| 必要なもの | 書き方 |
|---|---|
| DOM 結線だけ (form features 不要) | `data-bind="@X"` |
| form の validation/submit + 値が `<input>` 内 | `f.field :X` + `<input data-field="X">` |
| form の validation/submit + 値が `<input>` の外 (子 component / 外部 signal) | `f.field :X, source: @X` |

「form を使うべきか data-bind か」が **validation / submit の有無** 一問で
決まる。

### §2 との関係 (部分覆し)

§2 を **完全に否定するのではなく、適用範囲を狭める** 改定:

- §2 の「`data-value` / `data-checked` 廃止」は維持 (両者の duplication
  は依然 mental cost)
- §2 の「input binding は form 経由が canonical」は **撤回**。代わりに
  「form は binding の集約 layer であり、binding 自体は data-bind が canonical」

§2 が完全に覆ったわけではなく、「form を中心に据える」一文だけが「form は
集約 layer に位置を譲る」に refine された。

### 影響

- **declarative coverage の拡大**: 検索ボックス / toggle / コレクション内
  input が `<input data-bind="@X">` の 1 directive で書ける。imperative
  `bind_input` への退避が要らなくなる
- **form gem の責務純化**: 「validation / submit の orchestration」が中心、
  「input ↔ signal sync」という低レベル仕事は data-bind / bind_input の
  共通レイヤに降りる
- **form gem の必須性は変わらず**: form-spec §1 の「form gem は core 機能」
  方針は維持。validation / submit の declarative API は form 経由が唯一
- **directive-spec §6.2** に data-bind が canonical として定義済み (§16
  の bare ident 拡張と組み合わせ可能)
- **decisions §16 と組み合わせ**: `data-each` 内の `<input data-bind="qty">`
  で iteration item の Signal field を per-row 子 component なしで bind 可能

### 反映先 spec

- 本 § が SSOT
- `lilac-directive-spec.md` §3 / §5 / §6.2 / §8 に data-bind の文法が
  既に反映済み (2026-05-19)
- `lilac-form-spec.md` §1 / §2 / §11.8 / §12 に「form は集約 layer」と
  3 経路 (data-bind / data-field / source:) の位置付けを反映 (本決定昇格と同時)
- `lilac-design.md` §4.5 を「form を中心に据える代償」から「form を集約
  layer に位置付けた帰結」に更新 (本決定昇格と同時)

### 実装

scanner / codegen / wasm_spec / examples の実装は 2026-05-18〜2026-05-19 に
完了:

- **runtime scanner**: `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb`
  に `dispatch_bind` (form-independent two-way binding) + `detect_bind_property`
  (input type による value / checked 自動選択) を追加
- **runtime compat rules**: `data-bind` と `data-field` が同一 element に
  共存したら build/runtime とも raise (`compat_rules.rb` SSOT pair)
- **CLI codegen**: `cli/lib/lilac/cli/codegen.rb` 内 `data-bind` directive
  対応、ivar / bare_ident 両形を emit
- **wasm_spec**: `runtime/mruby-lilac-directives/wasm_spec/test_directive_bind_runtime.rb`
  でランタイム挙動を網羅
- **example migration**: `examples/runtime-only/lilac-receipt.html` の
  line-row input を `data-bind` 化。2026-05-19 に §16 bare ident で
  さらに簡素化 (per-row 子 component 不要に)

decisions への昇格は spec 反映が遅れていたため 2026-05-20 の本決定タイミングで
最終確定。

---

## 22. Form 関連の CLI build-time lint を廃止 (§6 部分覆し)

### 22.1 判断

`cross_ref_linter` の **form 関連 cross-reference checks**
(`data-form` / `data-field` / `data-button` を `form do |f| f.field :x
end` 系の Ruby 宣言と突き合わせる lint) と、それを支える
`script_analyzer` 側の form block tracking
(`@declared_forms` / `@declared_fields` / `@declared_buttons`、
`with_form_block_frame` / `record_field_or_button_declaration` 等)
を全廃する。Form 直交 lint は runtime に一本化する。

### 22.2 背景

§6 で CLI と runtime の lint severity 整合を取り、`data-button` 未宣言を
build error 化していた。同時に form 関連の AST 解析が
`script_analyzer.rb` (~80 行) + `cross_ref_linter.rb` の
`FORM_REF_CHECKS` テーブルとして CLI 側に積み上がっていた。

その後 form 分離 (form gem を真の plug-in として core / CLI から
切り離す方向) の検討で次が判明:

- form 関連の lint は runtime 側で **すでに同等の検出ができている** —
  `data-button` 未宣言は runtime が `Lilac::Error` を raise、`data-field`
  未宣言は auto-register + `Lilac.logger.warn` を出す
- CLI 側 form 解析は **form gem の Ruby 構文 (`form do |f| f.field`) を
  Prism マッチで認識** しており、form gem の API 形に hardcode 依存
- これは form 分離の **最大の障壁**。CLI に「form を知らない」状態を
  作るには、まずこの依存を消す必要がある
- そのまま残して plug-in 化するなら `script_analyzer` に extension 機構を
  足し form gem 側に visitor を持たせる必要があり、現時点の plug-in 需要
  (1 gem) に対して過剰設計

### 22.3 rationale

- **runtime が canonical** (§1) の原則をそのまま適用: form の挙動について
  runtime が単一の真実、CLI は無理に追わない。これまでの form lint は
  runtime / CLI の二重実装で、§1 と整合しない箇所だった
- 「`lilac-cli` は optional な最適化レイヤ」(§1 / README) という建付け上、
  build-time 早期エラー化は **必須ではなく nice-to-have**。runtime 側の
  エラーメッセージで実用上は十分
- 削除により `script_analyzer.rb` は 367 → ~290 行、`cross_ref_linter.rb`
  は FORM_REF_CHECKS テーブル + 関連メソッド ~70 行が消える
- form 分離 (将来の作業) において CLI 側の form-specific コードは
  template_ast / codegen / directive にもあるが、**最も深い結合 (Ruby AST
  解析) を先に除去** することで残作業の見通しが立つ
- 将来 lint を再導入するなら 3 経路 (案 A: register API で form plug-in
  に持たせる、案 B: wasmtime-rb 経由の runtime introspection、案 C:
  `lilac doctor` / `lilac lint --strict` 等の独立コマンド) のいずれかで
  対応可能。**本決定はそのいずれも閉ざさない** (build artifact / runtime
  挙動は不変)

### 22.4 トレードオフ

- **失うもの**: `f.button :submitt` のような typo を build 時に検出する
  機能。component mount 時の `Lilac::Error` メッセージで代替されるため、
  ユーザは初回 interaction で気づく形になる
- **CI 影響**: `lilac build` の exit code を lint signal として CI で
  使っていたチームには regression。pre-1.0 期なので CHANGELOG で
  announce する程度で十分
- **§6 との整合**: §6 は「CLI と runtime の severity を揃える」決定だが、
  本決定は「CLI で同等チェックをしない」方向。§6 の精神 (=
  runtime と CLI の振る舞いを一貫させる) は維持されており、その実現
  手段が「CLI が独自に検証」から「CLI は検証せず runtime に委ねる」に
  変わった、と捉える
- `cross_ref_linter.rb` の `Result(warnings:, errors:)` API は残す。
  現状 `errors` を立てる check はゼロだが、将来別の fatal check を
  足したくなったときに Builder 側の分岐を再配線せずに済む

### 22.5 実装

- `cli/lib/lilac/cli/script_analyzer.rb`:
  Result struct から `declared_forms` / `declared_fields` /
  `declared_buttons` フィールド削除、対応する `declares_form?` /
  `declares_field?` / `declares_button?` メソッド削除、Visitor から
  form block stack 関連 (`with_form_block_frame`, `form_block_call?`,
  `record_field_or_button_declaration`, `form_name_arg`,
  `first_symbol_arg`, `block_first_param_name`) を削除
- `cli/lib/lilac/cli/cross_ref_linter.rb`:
  `FORM_REF_CHECKS` 定数、`lint_form_ref` / `emit_form_ref_warning`
  メソッド、`lint` 内の FORM_REF_CHECKS loop を削除
- `cli/test/test_cross_ref_linter.rb`:
  form / field / button 関連の test ケース 8 件削除
- `Lilac::CLI::Directive` の `form_scope` / `field_input_ref` フィールドは
  **残す** — codegen.rb の `emit_form` / `emit_field` / `emit_button` が
  引き続き使用するため。これらは form 分離の次段階で扱う

### 22.6 後続作業

form 分離は 4 階層 (script_analyzer / cross_ref / template_ast +
codegen 文字列 / runtime directives gem の FormWiring) のうち、
本決定で最も深い階層を除去した。残る階層を扱う場合の路線:

- **Runtime FormWiring の plug-in 化** — directives gem の `Scanner` に
  `register_directive` API を作り、form gem 側に form_wiring を移動
- **CLI template_ast / codegen の plug-in 化** — 同じ register API を CLI
  にも作り、form 用 emitter を form gem 配下に移動
- いずれも本決定とは独立した別マイルストーン。本決定は単独で完結する

---

## 23. Plug-in 機構: runtime canonical の延長としての runtime fallthrough

決定日: 2026-05-23

### 23.1 判断

「**配布時 modular 化**」を目的とする plug-in 機構を、§1 (runtime
canonical) の原則に厳密に従って実装する。Lilac 公式が機能を追加する際に
**runtime mrblib 1 ファイル**だけで完結し、CLI には手を入れない。

- **`Lilac::Directives::Scanner.register_directive(pattern:, kind:, phase:) { block }`**
  を plug-in 用 API として正式採用 (block 形式)
- Plug-in 作者は **mrblib に 1 ファイル書く**だけで directive を追加可能
- **CLI codegen 出力の `bind_template_hook` 末尾に
  `Scanner#scan_extensions(root.to_js, item:, except:)` を常に emit**
  する。Mount 時に runtime Scanner が DOM を走査し、CLI が知らない
  data-* directive を dispatch
- **`except:` には CLI が hand-tuned emit した kind を渡す**
  (現状: `[:form, :field, :button]` — form gem の hand-tuned emit と
  重複しないため)。Codegen が `EMITTERS.keys` から導出
- **`scan_extensions` は extension directive のみ dispatch**。Built-in
  directive (data-text 等) は extract_directives で skip
  (codegen が precompile 済み)。tag_hooks / collect_hooks も skip
  (これらは `lilac-full` の full scan path 専用、`lilac-compiled` では
  対応する CLI hand-tuned emit がカバーする)
- **Plug-in 作者が CLI を触るのは「extension を hand-tune して最適化したい
  場合のみ」** (例: form_extension.rb)。これは built-in directive の
  `emit_text` と同じ位置付けで、optional な optimization

### 23.2 背景

Step 2 (form 分離 + 拡張点 API 導入) で plug-in 機構ができたが、
Phase 1-5 でさらに「named API + AST scanning + naming convention」を
重ね、~500 行のインフラを構築。検証の結果、これらは §1 の原則
(runtime canonical) と緊張関係にあった:

- `register_named_directive` + AST scanning は、CLI が runtime を
  "読み取って" emitter を派生させる構造。CLI が runtime に依存する
  方向は、本来の "CLI は optional optimization" と逆向き
- 配布 modular 化 (Lilac 公式が機能を独立 gem として配る) という
  実際の目的に対しては overkill

User が明示した前提:
- 配布時に core + 個別機能 gem の選択が可能
- 公式が機能追加するたびに CLI を触るのは避けたい
- Runtime が canonical (§1) を厳密に守る

これを満たすには **runtime fallthrough** が筋。CLI は built-in だけを
hand-tune し、extension directive は runtime Scanner が mount 時に
拾う。

### 23.3 rationale

- **§1 (runtime canonical) を plug-in 領域にもそのまま適用**。
  CLI は built-in 用の precompile に専念
- **Plug-in 作者は mrblib 1 ファイル** で済む (CLI 不在で動く)
- **`lilac-compiled` でも plug-in 動作**: `mruby-lilac-directives` gem
  が compiled bundle に含まれているので Scanner#scan_extensions が動く
- **複雑度の劇的削減**: ~500 行のインフラ (PluginScanner、register_named_directive、
  Validation モジュール、handler / hook_X 規約、NAME_PATTERN、RESERVED_NAMES、
  Component#scanner accessor) を全部撤回
- **§17 のスコープを core grammar に限定** (§17 の本来の意図に戻る)

### 23.4 トレードオフ

- **Mount 時の追加コスト**: extension directive を持つ component で
  DOM walk 1 回追加。component あたり ~数十 μs、許容範囲
- **Build-time error が出ない**: Plug-in directive の値 typo は
  mount 時 `Lilac.logger.error`。§22 (form lint 撤回) と同じ方針
- **Block dispatch の stack trace**: Anonymous proc としてしか追えない
  (named method より追いにくい)。実害は logger.error の context で緩和
- **Phase :pre が built-in と協調しない**: scan_extensions は
  bind_template_hook の末尾で走るので、built-in より後。Phase :pre が
  必要な plug-in (form のような) は **CLI hand-tune (form_extension.rb)
  を併設**することで built-in と協調する。第三者 plug-in が同様の
  協調を必要としたら、同じく CLI hand-tune を書く
- **tag_hook / collect_hook は compiled では実行されない**: これらは
  `lilac-full` の full scan path 専用。Form の collect_hook
  (`validate_form_element` 等) は compiled では発火しない (dev-time の
  validation として `lilac-full` でのみ実行されればよい)
- **Extras gem のような plug-in は `lilac-compiled.rb` 直接 dep が必要**:
  Build config に `conf.gem` で明示。これは「配布時 modular 化」目的と
  整合 (ユーザが選んで gem を include する)

### 23.5 実装

- **Runtime**:
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb`:
    - `register_directive(pattern:, kind:, captures_name:, phase:) { block }` 形式 (Step 2 と同等)
    - `scan_extensions(node_js, item:, except:)` メソッド追加
    - `dispatch_extensions_only` ヘルパ (tag_hooks をスキップする dispatch_record の variant)
    - `build_record` / `collect_subtree` / `extract_directives` に
      `extensions_only:` / `except:` パラメータを追加
  - `runtime/mruby-lilac-directives/mrbgem.rake` のデフォルト dep を path
    付きに更新 (lilac-compiled の transitive dep 解決のため、§23.6 参照)
- **Runtime (form / extras)**:
  - `runtime/mruby-lilac-form/mrblib/lilac_form_wiring.rb`:
    `register_directive` (block) で `:form` / `:field` / `:button` を登録、
    `register_collect_hook` / `register_tag_hook` も block で
  - `runtime/mruby-lilac-extras/mrblib/lilac_extras_*.rb`:
    `register_directive` (block) で `:tooltip` / `:autofocus` を登録
- **CLI**:
  - `cli/lib/lilac/cli/codegen.rb`:
    - `build_scope_body` の末尾に `scan_extensions_trailer` 呼び出し
    - `scan_extensions_trailer` は `EMITTERS.keys` を `except:` に渡す
      `scan_extensions` 呼び出し 1 行を emit
  - `cli/lib/lilac/cli/form_extension.rb` は **そのまま残す**
    (form 用 hand-tuned emit。built-in 級 optimization)
  - `cli/lib/lilac/cli/plugin_scanner.rb` 削除
  - `cli/lib/lilac/cli/builder.rb` の plugin scan 関連削除
- **Build config**:
  - `build_config/lilac-compiled.rb`: `mruby-lilac-directives` +
    `mruby-lilac-extras` を direct dep として明示 (もとは form gem の
    transitive dep だったが、extras 追加時に mruby の dep resolution
    で `mruby-regexp-compat` が解決できなかったため明示が安全)

### 23.6 §17 への影響 (本 §23 と整合)

§17 の SSOT 構造に補足を追加:

- **Plug-in directive の dispatch logic は mrblib 単一 SSOT**
  (CLI は知らない、知る必要もない)
- **§17 の diff-0 ペアルールの対象は core grammar に限定**
  (`Value` / `Grammar` / `ClassParser` / `compat_rules`)。
  Plug-in は対象外
- `Scanner` に新メソッド `scan_extensions` を追加 (runtime fallthrough 用)

### 23.7 後続作業 (本決定スコープ外)

- `data-on-X` のような **captures_name 系 directive** は plug-in 用
  API では現状サポート (block 形式の `register_directive` で `captures_name: true`)
  だが、第三者 plug-in が実際に使う想定なし。需要が出てきたら検討
- Plug-in 作者向けドキュメント (`docs/lilac-directive-plugin-spec.md`
  等) 整備
- `lilac dev` の **hot-reload** で mrblib 変更を即反映する仕組み
- `lilac-compiled` build で plug-in gem 不在を **build error として検出**
  する仕組み (現状は runtime で no-op、症状の追跡が困難なケースあり)
- Form の **collect_hook 由来 dev-time validation** を
  `lilac-compiled` でも動かす場合の方針 (現状は `lilac-full` 専用)

### 23.8 ステータス

完了 (2026-05-23):

- Runtime: `register_directive` + `scan_extensions` 実装、72 spec files pass
- CLI: codegen 末尾に scan_extensions trailer emit、PluginScanner 撤回、
  470 CLI test runs pass
- Form / Extras: block 形式の `register_directive` に書き戻し、動作確認
- `lilac-compiled` build: 2.9M bundle、extras 動作確認
- 削減: ~500 行 (Phase 1〜§23 当初版で構築したインフラを撤回)

### 23.9 経緯 (sunk cost の記録)

Step 2 (form 分離) 完了後、ergonomics 改善 (mrblib only / 1 ファイル
plug-in) を目指して以下を順次構築・撤回した:

- §23 第 1 版: `register_named_directive` + `handler:` + `hook_X` 命名 +
  4 軸 metadata schema (`value:` / `allowed_tags:` / `conflicts_with:` /
  `iteration:`) + AST scanning + Validation diff-0 ペア + Component#scanner
- §23 第 2 版: metadata schema を `value:` のみに簡素化
- §23 第 3 版: `value:` も撤回、`(name, handler:)` 最小化
- §23 第 4 版 (本決定): named API 自体を撤回、`register_directive` (block)
  + runtime fallthrough に統一

User フィードバックで「配布 modular 化 + CLI 不要 + runtime canonical 厳密
適用」が真の目的と判明し、AST scanning と命名規約は overkill だった
ことが明確化された経緯。

## 24. Plug-in 配布形態: `lilac-compiled` core + 個別 npm plug-in パッケージ (superseded by §25)

決定日: 2026-05-23 (superseded 同日)

本節の方針 (npm 経由の plug-in 配布) は §25 で覆された。理由 / 経緯は
§25 で詳述。実装は §24 のものを一度全部入れた後で §25 にリセットした
形になっている (本 doc 内に sunk cost の記録として両節を残す)。

### 24.0 §25 による上書き要点

- plug-in は **rubygems 配布**に統一 (`lilac-plugin-extras` 等の gem)
- `lilac-compiled` wasm は **npm 配布しない** (`lilac-wasm-bin` gem 経由のみ)
- npm に残るのは `@takahashim/lilac-full` 1 つ、用途は CDN 経由 (`esm.sh`
  / `jsdelivr` 等) の「お試し」入り口に限定
- 詳細は §25 を参照

以下の §24.1 〜 §24.7 は元判断のスナップショット (覆された後も history
として残す)。



### 24.1 判断

§23 の plug-in 機構 (runtime fallthrough) を **配布形態の分割**まで貫徹する。
公式が複数の "compiled variant" を組み合わせ別に配るのではなく、**core 1
variant + 個別 plug-in npm package** という形で配布する。

- **core wasm variant は 1〜2 種類に絞る**:
  - `@takahashim/lilac-full` — mruby-compiler 込み、router/async/extras
    も linked (現状維持)
  - `@takahashim/lilac-compiled` — compiler なし、`vm.loadBytecode` 駆動。
    `mruby-lilac` / `mruby-lilac-directives` / `mruby-lilac-form` のみ同梱
    (form は §2 で core 確定)
  - 必要に応じて将来 `lilac-compiled-minimal` (form 抜き) を検討するが
    **当面は 1 つの compiled variant に集中**
- **Plug-in は個別 npm package**:
  - `@takahashim/lilac-plugin-extras` — `data-tooltip` / `data-autofocus`
    (directive plug-in。`register_directive` で Scanner に登録)
  - `@takahashim/lilac-plugin-router` — `Lilac::Router` (class plug-in。
    pre-load で class を提供)
  - `@takahashim/lilac-plugin-async` — `Fetchy` / `Lilac::Resource` /
    selector helpers (class plug-in)
  - 各 package は **pre-compiled `.mrb` bytecode** を同梱
- **ユーザの使い方**:
  ```js
  import { boot } from "@takahashim/lilac-compiled";
  import { loadExtras } from "@takahashim/lilac-plugin-extras";

  const extrasMrb = await loadExtras();
  await boot({ bytecode: appMrb, plugins: [extrasMrb] });
  ```
  `boot()` が `plugins` を **`appMrb` より先に** `vm.loadBytecode` する
- **Plug-in 作者向け build path**: 既存の `mrbc-host.wasm` +
  `WasmMrbcDriver` を再利用。`lilac plugin-build my_plugin.rb -o my_plugin.mrb`
  という subcommand を新設し、`.lil` build pipeline と同じ wasm-driven mrbc
  経路で `.mrb` を生成

### 24.2 背景

§23 で「公式の機能追加は mrblib 1 ファイルで完結 + CLI 不要」が実現したが、
**配布側はまだ単一 monolithic wasm**:
`@takahashim/lilac-compiled` に extras も form も全部入っている。

User 要件 (2026-05-23):
- いろんな variant を公式から配布するのは避けたい
- compiled 版についてはコアを 1〜3 種類、あとは plugin として個別配布

問題: 機能の組み合わせ別に compiled wasm を配るとすぐ組合せ爆発する
(`with-extras` / `with-router` / `with-extras-router` …)。これは「runtime
canonical」と「modular 配布」の両立に反する。

mrb_load_irep が `lilac-compiled.wasm` でも完全動作することは §23 完了後に
検証済み (`vm.loadBytecode` API として既に expose 済み)。
これを利用すれば **core wasm を 1 つに保ったまま plug-in を後乗せ**できる。

### 24.3 rationale

- **§23 と完全整合**: plug-in は mrblib 1 ファイル + `register_directive` の
  block 形式。配布時には mrbc で `.mrb` 化するだけで内容は変わらない
- **mrb_load_irep は既に動く**: C / wasm export / JS bridge
  (`vm.loadBytecode`) は実装済み。Lilac 側で `boot({ plugins })` の hook を
  足すだけ
- **mrbc-host.wasm の再利用**: plug-in 作者向け mrbc 経路を別途用意せず、
  既存の `WasmMrbcDriver` をそのまま流用できる (= 「lilac plugin-build」が
  既存 `BytecodeBuilder` の薄いラッパー)
- **variant 爆発回避**: core は 1〜2 個に固定。機能追加は npm package
  追加で表現される

### 24.4 トレードオフ

- **mruby version lock**: plug-in `.mrb` は core wasm に同梱した mruby と
  binary-compatible である必要 (`MRB_BINARY_*` magic / opcode version)。
  npm の `peerDependency` で `@takahashim/lilac-compiled@^X.Y` を強制 +
  mismatched version は `vm.loadBytecode` が `RubyError` を返すので
  ユーザに見える形で失敗する
- **Pure Ruby plug-in のみ**: C 拡張は core wasm に linked 済みでないと
  使えない。Plug-in は `runtime/mruby-*-pure-ruby-only` 制約。第三者が
  C 拡張を含めたい場合は `lilac-compiled` を fork してビルドする必要あり
  (= 公式 plug-in scope 外)
- **Boot 順序の依存**: plug-in は user code より先に load する規約が必須
  (`register_directive` 呼び出しが先に走らないと user component の mount
  時に extension が見つからない)。`boot()` の `plugins:` option で強制
- **Plug-in 内部 API は core の internal に依存**:
  `Lilac::Directives::Scanner.register_directive` の signature が plug-in
  と core で binary-compatible である必要。Core 側の API 変更が plug-in
  package の version bump を強制 (= 適切に semver 管理する)
- **Bundle size 二重カウント**: ユーザの dist には core wasm (~2.9MB) と
  plug-in .mrb (数 KB〜数十 KB) が両方乗る。Tree-shake はできない
  (.mrb 内の不要な class まで含む)。許容範囲

### 24.5 実装

Phase 1: `lilac plugin-build` subcommand (CLI) — 完了

- `cli/lib/lilac/cli/plugin_build.rb`:
  - 入力: `*.rb` ファイル (1 つ以上を結合して compile)
  - 出力: `*.mrb` (mrbc 経由)
  - `BytecodeBuilder#compile_to_bytes` (新規抽出) 経由で既存 mrbc backend
    chain (binary / wasm-driven) を再利用
  - `Lilac.start` は **付加しない** (plug-in は library 扱い)
- `cli/lib/lilac/cli/command.rb`: `plugin-build` subcommand + help を追加
- `cli/test/test_plugin_build.rb`: single / multi input / nested output dir /
  missing input / compile error を網羅

Phase 2: `boot({ plugins })` hook (npm wrapper) — 完了

- `npm/lilac-compiled/index.js`:
  ```js
  if (opts.plugins !== undefined) {
    if (!Array.isArray(opts.plugins)) {
      throw new TypeError("boot: `plugins` must be an array of bytecode buffers");
    }
    for (const p of opts.plugins) {
      vm.loadBytecode(p instanceof Uint8Array ? p : new Uint8Array(p));
    }
  }
  vm.loadBytecode(bytes);  // user code (last)
  ```
- `npm/lilac-full/index.js`: 同等の hook (compatibility のため)
- `index.d.ts`: `BootOptions.plugins` 型定義

Phase 3: `@takahashim/lilac-plugin-extras` package 作成 — 完了

- `npm/lilac-plugin-extras/` 一式 (`package.json` / `index.js` /
  `index.d.ts` / `README.md` / `LICENSE`)。`peerDependency` を **optional**
  にして lilac-full でも使えるよう構成
- `Makefile`: `lilac-plugin-extras` ターゲット +
  `npm-pack` / `npm-clean` 統合
- `.gitignore`: `/npm/**/*.mrb` (build artifact なので tracking しない)
- `build_config/lilac-compiled.rb` から `mruby-lilac-extras` を除外 →
  wasm size 約 20 KB 減

Phase 4: ドキュメント — 完了

- `docs/lilac-plugin-spec.md` 新設 (本決定の how-to を集約)
- `docs/README.md` の仕様レイヤテーブルに `lilac-plugin-spec` を追加
- `docs/lilac-design.md` への "plug-in 配布形態" 節は未着手 — design.md は
  原則レイヤなので、配布形態のような implementation detail は今のところ
  decisions / plugin-spec で十分と判断

Phase 5: E2E parity test — 完了

- `test/parity-fixtures/extras/` 新規 (`data-tooltip` 動作確認用)
- `test/parity-runner.mjs`: `loadCompiled` に `pluginMrbPaths` 引数追加 +
  `SCENARIOS.extras` で extras.mrb を pre-load
- 結果: `lilac-compiled.wasm (extras 抜き) + extras.mrb` が `lilac-full`
  と DOM-byte 一致

Phase 6: router / async plug-in 化 — 完了

- `npm/lilac-plugin-router/` (`Lilac::Router` を提供する class plug-in)
- `npm/lilac-plugin-async/` (`Fetchy` / `Lilac::Resource` を提供する
  class plug-in)
- Makefile target / npm-pack 統合 / `.gitignore` の glob 化 (`/npm/**/*.mrb`)
- build_config 変更なし — 両 gem は元々 lilac-compiled に linked
  されていなかったため、新規 plug-in package 追加のみで完結
- lilac-full は両 gem を引き続き linked のまま (§24.1 の通り)

### 24.6 後続作業 (スコープ外)

- **第三者 plug-in 用テンプレート repo** (cookiecutter 的)。現状は
  `npm/lilac-plugin-extras/` が事実上のテンプレートで、README で構造を
  示すだけで足りる可能性が高い
- **Plug-in registry / discovery** (npm 検索で `lilac-plugin-*` を見つける
  慣習を README で示すだけで十分か、専用 page が必要か)
- **C 拡張 plug-in** が必要になった場合の道筋 (= `lilac-compiled` の fork
  ビルドを公式が用意するか、ユーザに任せるか)
- **Plug-in `.mrb` の hot-reload** (`lilac dev` 統合 or
  `lilac plugin-build --watch`) — proposals.md に proposal 記録済み
- **design.md への "plug-in 配布形態" 節追加** — 当面 decisions §24 +
  plugin-spec で代替

### 24.7 ステータス

**完了 (2026-05-23)**。

Phase 1〜6 すべて main に commit 済み:

| Phase | 内容 | 主要コミット |
|---|---|---|
| 1 | `lilac plugin-build` subcommand | `feat(cli): add lilac plugin-build subcommand …` |
| 2 | `boot({ plugins })` hook | `feat(npm): support boot({ plugins }) …` |
| 3 | extras を plug-in 化 + build_config から除外 | `feat: split extras into @takahashim/lilac-plugin-extras …` |
| 4 | docs (plugin-spec.md 新設) | `docs: document plug-in distribution model …` |
| 5 | E2E parity test | `test(parity): cover lilac-compiled + extras plug-in load …` |
| 6 | router / async plug-in 化 | `feat: add @takahashim/lilac-plugin-router npm package`<br>`feat: add @takahashim/lilac-plugin-async npm package` |

途中で fix した bug (`scan_extensions` trailer の `t.root.to_js` →
`t.to_js`) は `fix(codegen): use t.to_js (not t.root.to_js) for
scan_extensions in iteration scope` で別 commit。

## 25. Plug-in 配布を rubygems に pivot、npm は `lilac-full` の CDN 配布のみに集約

決定日: 2026-05-23

### 25.1 判断

§24 (plug-in を npm で配布、`lilac-compiled` も npm package として持つ)
を覆し、次のモデルにする:

- **plug-in は rubygems で配布**:
  - `lilac-plugin-extras` / `lilac-plugin-router` / `lilac-plugin-async`
    (それぞれ既存 mrbgem に対応する Ruby gem を新設)
  - gem の中身は **mrblib `.rb` source**。pre-compiled `.mrb` は含めない
  - lilac-cli が **Bundler.load.specs から `metadata["lilac_plugin"]`
    を持つ gem を発見** し、build 時に各 mrblib を `lilac plugin-build`
    相当で `.mrb` に焼いて `dist/plugins/` に stage、生成 boot script に
    `loadBytecode` を inject する
- **`lilac-compiled` wasm は npm 配布しない**:
  - lilac-cli ユーザーは `lilac-wasm-bin` gem (proposals.md 参照) から
    vendor。monorepo 内では `build/lilac-compiled.wasm` を直接使う
  - 非 lilac-cli ユーザーが lilac-compiled を直接扱う path は廃止
    (代わりに Mode 1 = CDN で lilac-full を使う)
- **npm に残るのは `@takahashim/lilac-full` のみ**:
  - 想定する利用形態は **CDN 経由のお試し** のみ:
    ```html
    <script type="module">
      import { boot } from "https://esm.sh/@takahashim/lilac-full";
      await boot();
    </script>
    <script type="text/ruby">
      class App < Lilac::Component
        # ...
      end
    </script>
    ```
  - npm install + bundler 等の Node ecosystem workflow は **想定しない**
    (Mode 1 ユーザーは Node / npm / Vite を一切持たない前提)
- **`lilac dev` 既定 target は `:full`** のまま (canonical で mrbc を経ない
  ので iteration が手軽)
- **`lilac build --target full` でも plug-in が動くようにする**:
  - 現状 `--target full` の dist HTML は `<script type="text/ruby">` を
    残して lilac-full の auto-scan に任せていた
  - plug-in load (`vm.loadBytecode`) を boot 順序に明示挿入するため、
    `--target full` の dist HTML も「明示 boot 形式」に切り替える

### 25.2 背景

§24 を実装し plug-in 機構が完成した直後、ecosystem 配布形態の比較を改めて
行った結果、§24 の npm 経由が Lilac の self-identity と合わないと判明:

| Framework | source 言語 | plug-in 配布 |
|---|---|---|
| SolidJS / Vue / Svelte / Astro | JavaScript | npm (= source 言語の package manager) |
| Jekyll / Bridgetown / Hanami | Ruby | rubygems |
| Phoenix LiveView | Elixir | hex |
| Hugo | Go | go module |
| **Lilac** | **Ruby** | **rubygems** (§25 で確定) |

「source 言語の package manager に従う」が JS 系以外のフレームワーク
共通のパターン。Lilac の source は Ruby、build tool は Ruby gem
(`lilac-cli`)、user の主要 workflow は `bundle exec lilac build` →
**Bridgetown / Jekyll 型の Ruby framework に近い**。

「Vite を使うなら npm」という直感は Lilac には当てはまらない (Lilac は
自前 build pipeline で Vite を経由しない)。

### 25.3 rationale

- **mruby version lock 問題が原理的に消える**: §24 では npm 上の
  pre-compiled `.mrb` と core wasm の mruby バージョンが一致する必要が
  あり `peerDependency` で頑張る設計だった。§25 では plug-in を **手元
  の mrbc-host.wasm でローカル compile** する → core wasm と同じ
  toolchain → 不一致が原理的に発生しない
- **Bundler auto-discovery で zero-config**: `gem "lilac-plugin-extras"`
  を Gemfile に書いてあれば自動。`lilac.config.rb` の明示 `c.plugins`
  設定は advanced override に降格
- **Lilac ecosystem の一貫性**: lilac-cli / lilac-wasm-bin / plug-in
  すべて rubygems に集約。ユーザーの mental model が単純化
- **runtime canonical (§1) は不変**: lilac-compiled wasm を保つことで
  「compiler なし production runtime」は引き続き提供される。npm 配布
  しないだけで仕組みは変わらない
- **Mode 1 (CDN お試し) のシンプルさ**: ユーザーは Node ecosystem 全部
  不要、HTML 1 枚 + `<script type="module">` で動く。Lilac の入口
  ストーリーが最短になる

### 25.4 トレードオフ

- **`--target full` boot 形式の変更**: 現在の auto-scan を明示 boot に
  切り替える必要があり、§20.6 / §20.7 (Pattern A boot helpers) で確立した
  自動 `Lilac.start` の流れと統合し直す必要がある
- **非 lilac-cli ユーザーが plug-in を使う path を提供しない**: §24 では
  npm + `boot({ plugins })` で hand-load する経路を残していたが、§25 では
  廃止。代わりに `gem install lilac-cli` を勧める (Lilac 開発は元々 Ruby
  必須なので前提は変わらない)
- **既に commit 済みの npm/lilac-plugin-* / npm/lilac-compiled を削除**:
  publish 前なので互換性負債はないが、commit log には残る。本節がその
  記録
- **lilac-wasm-bin gem の release 整備が必須**: `lilac-compiled.wasm` を
  ユーザーに届ける唯一の path になるため、gem release flow を実装する
  必要 (proposals.md §「lilac-wasm-bin gem」参照)
- **`@takahashim/lilac-full` npm package の役割が狭まる**: ESM CDN 専用に
  なる。`peerDependency` / `package-lock` を伴う node_modules 設計は
  想定外

### 25.5 実装

Phase A: decision lock (本節)

Phase B: gem infrastructure

- `runtime/mruby-lilac-{extras,router,async}/lilac-plugin-*.gemspec` x3:
  - `spec.metadata["lilac_plugin"] = "true"` で discoverable に
  - `spec.files = Dir["mrblib/**/*.rb", "*.gemspec"]`
- `cli/lib/lilac/cli/plugin_discovery.rb`:
  - `Bundler.load.specs` から `metadata["lilac_plugin"]` 付き gem を返す
  - 各 gem の `mrblib/*.rb` のリストを返す
- `Builder` 統合:
  - `build` の頭で PluginDiscovery を実行
  - 各 gem を `PluginBuild` で compile → `dist/plugins/<gem-name>.mrb`
  - 生成 boot script に inject (両 target)

Phase C: `--target full` plug-in 注入

- dist HTML を明示 boot 形式に統一:
  ```html
  <script type="module" data-lilac-bootstrap>
    import { createVM } from "./vendor/lilac-full/mruby-wasm-js/index.js";
    const vm = await createVM({ wasm: "./vendor/lilac-full/lilac.wasm" });
    vm.loadBytecode(...);  // plug-ins
    vm.evalScript("script[type='text/ruby']");
    vm.eval("Lilac.start");
  </script>
  ```
- 既存の auto-scan 経路は CDN お試し時 (`boot()` helper 経由) でのみ使用

Phase D: npm cleanup

- `npm/lilac-compiled/` 削除
- `npm/lilac-plugin-{extras,router,async}/` 削除
- `npm/lilac-full/index.js` の `boot({ plugins })` hook 削除 (Mode 1 =
  no-plugin の前提に合わせ)
- Makefile から関連 target 削除
- `cli/lib/lilac/cli/compiled_runtime_resolver.rb` から
  `node_modules/@takahashim/lilac-compiled` の lookup path を削除

Phase E: downstream consumers

- `examples/plugin-extras/`: `c.plugins` (path) → `Gemfile` の
  `gem "lilac-plugin-extras"` に書き換え。`README` 全面改訂
- `test/parity-runner.mjs`: `npm/lilac-plugin-extras/extras.mrb` を
  直接参照していたのを、`runtime/mruby-lilac-extras/mrblib/` を
  `lilac plugin-build` で焼いた一時 `.mrb` を使う形に
- `docs/lilac-plugin-spec.md`: §3 (build) / §4 (配布) / §5 (利用) を
  gem-centric に書き換え

Phase F: tests

- PluginDiscovery test (mock Bundler specs)
- Builder integration test (auto-discover + 両 target の boot 注入)
- npm 経路削除に対応した既存 test の更新

### 25.6 後続作業 (スコープ外)

- **wasmtime-rb の `wasm_exceptions` engine option release を待つ**:
  upstream PR
  [bytecodealliance/wasmtime-rb#599](https://github.com/bytecodealliance/wasmtime-rb/pull/599)
  が 2026-05-20 に merge 済みだが、まだ rubygems に release されていない
  (最新 release v44.0.0 は 2026-05-06)。当 release を含む新 version
  (見込み v45 系、2026-06 上旬〜中旬予定) が出たら:
  - `wasm-bin/lilac-wasm-bin.gemspec` の `spec.add_dependency "wasmtime", "~> 44.0"`
    を `"~> 45.0"` (or 該当 version) に bump
  - `cli/Gemfile` の TEMPORARY な local-checkout fallback を削除
  - lilac-cli / lilac-wasm-bin の **公式 release を始める** ことが
    現実的になる (それまでは monorepo の TEMPORARY pin で開発継続)
- **lilac-wasm-bin gem の release 整備**: 現状 monorepo 内には `wasm-bin/`
  スケルトンがあるが、gem release flow (CI で wasm を bundle してから
  publish) は未着手。上記 wasmtime-rb release と連動して着手。
  proposals.md §「lilac-wasm-bin gem」を昇格させる形で別決定として扱う
- **第三者 plug-in テンプレート repo** (引き続き未着手)
- **plug-in registry / discovery 強化** (gem search で `lilac-plugin-*`
  が見つかる慣習 + README ガイドで十分か検証)
- **`lilac dev` の plug-in hot-reload** (proposals.md §「Plug-in .mrb の
  hot-reload」を gem 配布前提に書き換えてから着手)

### 25.7 ステータス

着手 (2026-05-23)。Phase A 完了後、B 〜 F を順次実装。

§24 の sunk cost: §24 を一度全部実装した分のコード (`npm/lilac-plugin-*`
3 つ + `npm/lilac-compiled` の boot hook + Builder の `c.plugins` 配線等)
は Phase D で削除されるが、§24 で確立した **mrblib / register_directive /
scan_extensions / `lilac plugin-build` subcommand / `PluginBuild` クラス**
は §25 でもそのまま使う。失われるのは「**配布チャンネルの選択**」だけで、
plug-in 機構そのものは継続。

## 26. 「plug-in」から「package」への用語 rename

決定日: 2026-05-23

### 26.1 判断

§24/§25 で「plug-in」と呼んでいた distribution unit を **「package」** に
rename する。rename 対象は **用語のみ**、機構そのもの (register_directive /
scan_extensions / mrblib auto-discovery) は不変。

- gem 名: `lilac-plugin-{extras,router,async}` → `lilac-{extras,router,async}`
- gemspec metadata: `"lilac_plugin" => "true"` → `"lilac_package" => "true"`
- CLI subcommand: `lilac plugin-build` → `lilac package-build`
- CLI クラス: `PluginDiscovery` / `PluginBuild` → `PackageDiscovery` / `PackageBuild`
- Config: `c.plugins = [...]` → `c.packages = [...]`
- Builder 内部: `copy_plugins!` → `stage_packages!`、`@plugin_dist_urls` →
  `@package_dist_urls`、manifest filename `lilac.plugins.json` →
  `lilac.packages.json`
- docs: `lilac-plugin-spec.md` → `lilac-package-spec.md`
- examples: `plugin-extras` → `package-extras`

### 26.2 背景

「plug-in」という呼称が **二系統で曖昧** だった:

1. **CRuby gem 期待との衝突**: `lilac-plugin-router` を `gem unpack` すると
   `lib/` が空で `mrblib/` だけある状態。CRuby gem のメンタルモデルを
   持ってきた user は「壊れてる?」「mrblib って何?」と困惑する
2. **directive plug-in と class plug-in の用語不整合**: extras は本物の
   「Lilac 拡張」だが router/async は単に Ruby class を提供するだけ。
   「Lilac に plug-in する」というメンタルモデルが router/async には
   合っていなかった

他フレームワーク命名を見渡した結果 (詳細は議論経緯):

- Vue: plug-in は厳密に `app.use()` する hook 持ちのもの限定
- Astro: integration
- VSCode / Browsers: extension
- Hugo: module
- Rails / Phoenix: 単に gem / package (特別な名前なし)

Lilac は **Ruby framework + wasm runtime** という構造上、どのカテゴリにも
完全に当てはまらない。検討した候補:

- `gem` — CRuby 期待を裏切るので不可 (本決定の trigger)
- `extension` — directive 系には合うが router/async には不正確
- `package` — 中立、distribution unit という意味だけを表す。多様な
  ecosystem (npm / pip / cargo) で確立。directive 系も class 系もカバー

### 26.3 rationale

- **中立性**: 「package」は中身を限定しない。directive を register する
  ものも、Ruby class を提供するだけのものも、同じ「Lilac package」と
  呼べる
- **CRuby gem との区別**: 「Lilac package」と呼ぶことで、これらが
  rubygems で配布されるが内部構造は CRuby gem と違う (mrblib) ことが
  暗黙に signal される
- **将来の拡張余地**: package は概念として「mrblib + assets + style + ...」
  と膨らんでも自然。extension だと「何を extend?」という質問が増える

### 26.4 トレードオフ

- **大量の rename 差分**: gemspec / CLI コード / docs / tests / examples
  全体に渡る。約 250〜300 行の機械的更新。pre-release の今だからできる
  作業。release 後だと breaking change になる
- **CLI subcommand 名の breaking change**: `lilac plugin-build` →
  `lilac package-build`。pre-1.0 なので許容範囲だが、scripts に書いた
  user は影響を受ける
- **history を残すため §23/§24/§25 内の "plug-in" 用語は維持**:
  decisions log は「当時の判断」を残すのが原則。これらは過去形として
  読めるよう、本 §26 から相互参照する

### 26.5 実装

機械的な rename。テストと example で動作検証する。

- 3 gemspec: file rename + spec.name + metadata key 更新
- CLI コード: 各 file rename + class rename + 内部参照更新
- Templates / scaffold: manifest filename + 例示更新
- Tests: file rename + 参照更新
- parity-runner: SCENARIOS の field 名更新
- examples: dir rename + Gemfile + README 更新
- docs: lilac-plugin-spec.md → lilac-package-spec.md (大幅 rewrite)、
  docs/README.md の index 更新、proposals.md の hot-reload 節も "package"
  用語に更新

### 26.6 後続作業

特になし。本 §26 は用語の整理であり、機能変更を伴わない。§25 の後続作業
(wasmtime-rb release 待ち / lilac-wasm-bin release pipeline / hot-reload
proposal の昇格判断 / 第三者 package template) は本決定の影響を受けず
そのまま継続。

### 26.7 ステータス

着手 (2026-05-23)。

## Appendix: 設計判断の年表

主要な判断とその spec 反映先:

| 判断 | 反映先 spec | 主要 commit / Phase | 本 doc 内 § |
|---|---|---|---|
| Runtime canonical 化 | `lilac-directive-spec.md` 全体 | Phase 0〜4(完了) | §1 |
| Form を中心機構に | `lilac-form-spec.md` §1, §11 | Phase A〜D 完了 | §2 |
| `data-value` / `data-checked` 廃止 | `lilac-directive-spec.md` §6.2 | Phase D 完了 | §2 |
| HTML helper 廃止 | `lilac-spec.md` HTML helper 章 | Phase D 完了 | §5 |
| bind_list legacy mode 廃止 | `lilac-spec.md` bind_list 章 | Phase D 完了 | §5 |
| Symbol 規約明文化 | `lilac-form-spec.md`, `lilac-spec.md` items 規約 | (随時)| §4 |
| CLI lint severity 整合 | `lilac-form-spec.md` §13 | 完了 (2026-05-18 CrossRefLinter 拡張) | §6 |
| directive 値の文法厳格化 | `lilac-directive-spec.md` §1.1, §3 | (継続)| §3 |
| `<input value>` からの auto-register | `lilac-form-spec.md` §5, §11.3.1, §11.7 | 完了 | §7 |
| form scope の決定規則 | `lilac-form-spec.md` §11.2, §11.2.1, §18.4 | 完了 | §8 |
| `<input form="...">` 属性の扱い | `lilac-form-spec.md` §11.2.2 | 完了 | §9 |
| stateful 子 input の form 組み込み(`FieldComponent` + `source:`) | `lilac-form-spec.md` §3.1, §5, §7, §18.2.1, §18.6 | 完了 | §10 |
| scanner one-pass + 2-phase processing | `lilac-form-spec.md` §18.4 | 完了 | §11 |
| Props 機構の導入(`data-prop-*` + `prop` DSL) | `lilac-props-spec.md` | Phase P1 完了、その後 P2 で拡張完了 | §12, §14 |
| `instance_variable_*` 等の metaprog を極力使わない(directives gem の 1 箇所に集約) | `lilac_directives_evaluator.rb` `lookup_ivar` | (随時) | §13 |
| lilac-full の bundle size 最適化(browser-only + explicit allow-list + -Oz) | `build_config/lilac-full.rb`, `Makefile` | 完了 (2026-05-19、-25.3% raw / -23.0% brotli) | §15 |
| `it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill | `lilac-directive-spec.md` §3 / §5 / §6.2、`lilac-props-spec.md` §7.5 / §7.6 | 完了 (2026-05-19) | §16 |
| directive binding は codegen が canonical / scanner gem は grammar reference + duplicate pair の SSOT 構造 (`Lilac::Directives::*` 統一) | (本 doc §17 が SSOT。実装は `cli/lib/lilac/directives/` ↔ `runtime/mruby-lilac-directives/mrblib/`) | 完了 (2026-05-19) | §17 |
| `lilac build --target compiled` が単一コマンドで deploy 可能な dist を産む(page-inline ruby 取り込み + target-namespaced vendor + CLI auto-vendor) | (本 doc §18 が SSOT。実装は `cli/lib/lilac/cli/builder.rb` + `compiled_runtime_resolver.rb`) | 完了 (2026-05-20) | §18 |
| Codegen positional `lilN`(`data-ref` 注入の廃止) — bind ID は build 時に発行せず runtime で per-scope DFS 位置として解決 | (本 doc §19 が SSOT。実装は `cli/lib/lilac/cli/template_ast.rb` + `runtime/mruby-lilac/mrblib/lilac_ref.rb`) | 完了 (2026-05-20) | §19 |
| Component scope rules(`.lil` project-global / page-inline page-local の 3 階層 + R1〜R4 build-time guard)+ `Lilac.start` 自動化(framework boot を user 空間から外す、idempotent + auto-inject) | (本 doc §20 が SSOT。実装は `cli/lib/lilac/cli/builder.rb` + `script_analyzer.rb` + `runtime/mruby-lilac/mrblib/lilac_registry.rb`) | 完了 (2026-05-20) | §20 |
| `data-bind` の復活と form の "集約 layer" 化(§2 部分覆し)— input binding は data-bind が canonical、form は validation / submit の集約。3 経路(data-bind / data-field / source:)で完全カバー | `lilac-directive-spec.md` §3 / §5 / §6.2 / §8 + `lilac-form-spec.md` §1 / §2 / §11.8 / §12 + `lilac-design.md` §4.5 | 完了 (2026-05-19 実装、2026-05-20 spec 反映 + 昇格) | §21 |
| Form 関連の CLI build-time lint 廃止(§6 部分覆し)— `data-form` / `data-field` / `data-button` の cross-reference check を削除、Ruby AST 側の form block tracking も全廃。form 直交 lint は runtime に一本化 | (本 doc §22 が SSOT。実装は `cli/lib/lilac/cli/script_analyzer.rb` + `cross_ref_linter.rb`) | 完了 (2026-05-22) | §22 |
| Plug-in 機構: runtime fallthrough(§1 の延長として配布 modular 化を実現)— `register_directive` (block) + CLI codegen 末尾の `scan_extensions` 呼び出しで、plug-in は mrblib 1 ファイルで完結。CLI hand-tune は built-in 級 optimization として optional | (本 doc §23 が SSOT。実装は `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` + `cli/lib/lilac/cli/codegen.rb`) | 完了 (2026-05-23) | §23 |
| Plug-in 配布形態: `lilac-compiled` core + 個別 npm plug-in(`mrb_load_irep` / `vm.loadBytecode` で後乗せ、`lilac plugin-build` subcommand で `.mrb` 生成、`mrbc-host.wasm` 再利用)— variant 爆発回避と modular 配布の両立 | (本 doc §24 が SSOT。実装は `cli/lib/lilac/cli/plugin_build.rb` + `npm/lilac-compiled/index.js` `boot({plugins})` hook + `npm/lilac-plugin-{extras,router,async}/` + `docs/lilac-plugin-spec.md`) | 完了 (2026-05-23)、その後 §25 により上書き | §24 |
| Plug-in 配布を rubygems に pivot — npm は `@takahashim/lilac-full` のみ (CDN お試し用途)、`lilac-compiled` も含めて plug-in 全部 rubygems、Bundler auto-discovery で zero-config。Lilac の Ruby 中心 self-identity と整合、mruby version lock 問題が原理的に消える | (本 doc §25 が SSOT。実装は `runtime/mruby-lilac-*/lilac-plugin-*.gemspec` + `cli/lib/lilac/cli/plugin_discovery.rb` + Builder 統合 + `--target full` 明示 boot 化 + npm/lilac-{compiled,plugin-*} 削除) | 着手 (2026-05-23)、その後 §26 で "plug-in" 用語を "package" に rename | §25 |
| 「plug-in」用語を「package」に rename — CRuby gem 期待との衝突回避 + directive 系 / class 系で意味の統一性確保。機構そのものは不変、命名だけ整理 | (本 doc §26 が SSOT。実装は gemspec/CLI コード/docs/tests/examples の機械的 rename) | 着手 (2026-05-23) | §26 |

各判断の詳細・例・段階移行は対応する spec を参照。

---

## このドキュメントの位置付け

- **対象**: Lilac 開発者(framework 自体の開発)、Lilac で実装する利用者
  (Lilac の "なぜそう書くか" を知りたい)、設計レビュアー
- **更新頻度**: **月単位で累積**。新判断が出るたびに節を追加
- **`lilac-design.md` との関係**: design.md は **設計原則 (why の中核)**、
  ここは **個別判断の log (how / when / what)**。design.md の原則は
  季節〜年単位の refinement、ここは継続的に追記される
- **spec doc との関係**: spec は "現状の取説"、ここは "決定の経緯と
  rationale"。spec を読んで疑問になった "なぜこうなっているか" がここで
  追える
- **過去判断の扱い**: 覆された判断は節を残し `(superseded by §N)` を
  付ける(歴史が doc 内で追える)
- **`lilac-proposals.md` との関係**: proposals.md は **未確定の提案** を
  扱う。本 doc は確定判断のみ。提案が確定したら本 doc に新節として追記
  + 年表更新、proposals.md からは削除する(昇格 operation の詳細は
  proposals.md 冒頭参照)
