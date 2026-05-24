# 16. `it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill

決定日: 2026-05-19

## 問題

`it.path`(`data-text="it.title"` 等)は directive grammar の中で **唯一の
path 構文**(他は identifier-only)で、Section 3 の「HTML 内にコードを書
かない」原則と摩擦があった。Phase E までは migration 期間中 ItPath を
受理しつつ dev_mode で deprecation warn を出していたが、grammar を 1 つに
畳めるなら早く畳む方が良い。

## 決定

`it.path` 構文(legacy `Value::ItPath`)を **runtime / CLI 双方から完全削除**。
value-binding 系 directive(`data-text` / `data-show` / `data-hide` /
`data-attr-*` / `data-css-*` / `data-bind` / `data-class` の hash value /
`data-each` の collection)はすべて **`@ivar` または `bare_ident`** の二択。

- `it.title` → `title`(bare ident)
- `it` 単独 → 構文として消滅(iteration item 全体を渡したいケースは
  そもそも稀で、必要なら parent で computed/expose にまとめる)
- `data-prop-X="it.Y"` → child 側で `prop :Y` 宣言 + auto-fill 経由
  (§7.6, [`lilac-props-spec.md`](./lilac-props-spec.md))

## 影響

- grammar table から `it_path` の行が消え、すべての value-binding が
  identifier-only に統一
- `data-each` body 外で bare ident を書いた場合は **parse 成功するが
  silent skip**(item context が無いため bind 不能)
- `data-prop-*` の bare ident だけは **literal interpretation**(`data-prop-status="todo"` は文字列 "todo")。iteration item field を渡したい場合は
  prop 宣言 + auto-fill で書く
- example HTML(receipt / kanban / todo / search)はすべて bare ident に
  移行済み

## 反映先 spec

- `lilac-directive-spec.md` §3(grammar)、§5(directive table)、§6.2
  (data-bind)、§6.5(data-prop-*)
- `lilac-props-spec.md` §7.5(data-prop-X 解釈)、§7.6(auto-fill)
- `lilac-proposals.md` の "`it.path` 全廃" 提案 → 本 §16 として昇格(提案
  本文は本 §で要約、proposals 側は削除可)

## 実装

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
