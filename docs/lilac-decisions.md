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
