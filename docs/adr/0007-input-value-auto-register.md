# 7. `<input value>` からの auto-register

## 7.1 判断

`<input data-field="X">` を scanner が発見し、対応 form に `:X` field が
**未宣言** の場合、HTML から **auto-register** する:

- **type**: `<input type="checkbox">` なら `:checkbox`、他はすべて `:text`
- **initial**: HTML の `value` 属性のみ参照(checkbox の `checked` 属性、
  textarea の textContent、select の selected option 等は **無視**)
- **validator**: 無し(常に valid)

Ruby で `f.field :X` が宣言されていればそれが優先(scanner は touchしない)。

## 7.2 背景

「input は form 経由が canonical」(§2)に決めた上で、単発 input
(検索ボックス、トグル、ステッパー等)も常に `form.field :query, initial: ""`
の 1 行を書く必要があった。検索ボックス 1 個のために form + field 宣言は
重く感じる場面が多い。

## 7.3 判断の rationale

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

## 7.4 トレードオフ

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

## 7.5 ステータス

実装済み。spec は本 §7 と form-spec §5 / §11.3 / §11.3.1 / §11.7 / §14 に反映。

---
