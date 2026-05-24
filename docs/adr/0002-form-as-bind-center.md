# 2. Form を input bind の中心機構に

## 2.1 判断

input / textarea / select / checkbox の declarative binding は **form 経由
が canonical**。汎用 `data-value` / `data-checked` は廃止、form の
`data-field` directive に統一。

## 2.2 背景

旧設計では:
- `data-value="@signal"` で input ↔ signal の双方向 bind(form 不要)
- `data-checked="@signal"` で checkbox の双方向 bind
- form gem は optional な validation helper(独自 directive 無し)

これだと:
- 「form と関係しない input は data-value、form 内は f.field + bind_input」
  という二重路線
- `data-value` と `data-field` 両方あると "どっち使うべきか" の判断
  コスト発生

## 2.3 判断の rationale

- **「input は form の field」と固定** することで mental model 一本化
- form gem に validation / dirty / touched / error の概念が乗っているので、
  どんな input でも自然に状態管理できる
- `form.field :query, initial: ""` の 1 行追加で済むなら、単発 input
  のオーバーヘッドも実用上問題なし
- spec の directive 数も 2 つ減る(`data-value` / `data-checked` 削除)

## 2.4 トレードオフ

- form gem が **core 機能化**(`lilac-compiled` 含む全 variant 同梱、現状の
  optional 位置付けを変更)
- 検索ボックスやトグル等を「form」と呼ぶ違和感(API ergonomics で緩和:
  `form.field :query, initial: ""` の 1 行で済むようにする)
- imperative `bind_input` は escape hatch として残す(per-row 編集
  input 等のため、f.array 実装まで)

---
