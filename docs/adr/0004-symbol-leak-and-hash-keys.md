# 4. Symbol leak 制約と Hash キー方針

## 4.1 判断

- **form field 名**: Symbol(source 静的、leak しない)
- **bind_list item Hash キー**: String 推奨(動的データ想定、Symbol leak 回避)
- **両者は別レイヤ** として共存

## 4.2 背景

mruby は **Symbol が GC されない**(intern table 永続)。動的生成した
Symbol が leak する制約がある。

歴史的に Lilac の bind_list items は String キー("`{"id" => 1}`")を
推奨してきた。一方 form gem は Symbol field 名(`f.field :email`)を採用。

## 4.3 判断の rationale

- form field 名は **source code に literal で書かれる**(`:email`)ので、
  intern される Symbol の集合は source の field 定義数で bounded → 安全
- bind_list items は **JSON / DOM 由来が多い**(`Lilac::JSON.parse` の返り
  値が String キー)→ 動的キー集合の可能性、Symbol leak リスク
- レイヤが違う = 慣行が違う、と spec で明文化(無理に一致させない)
- 将来 form nesting / array でも **flat path Symbol を作らない**(nested
  object 構造で表現)ことを spec 規約に組み込み、Symbol 安全を維持

## 4.4 トレードオフ

- 利用者は「form は Symbol、items は String」を覚える必要
- ただし HTML 側(`data-field="email"` / `data-key="id"`)は両方 String
  なので、template ベースで考えれば差を意識しない
- evaluator が両方を受け入れる lenient な lookup(Symbol → String
  fallback)で実装されており、ソース literal Hash で `{name: "x"}` と
  書いても動く(spec 上は String 推奨だが実装は寛容)

---
