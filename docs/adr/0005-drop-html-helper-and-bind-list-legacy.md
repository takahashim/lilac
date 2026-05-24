# 5. HTML helper / bind_list legacy mode の廃止

## 5.1 判断

`Lilac::HTML.tag` / `HTML(...)` / `HTML.safe_join` / `HTML.raw` /
`HTML::Safe` を廃止。`HTML.escape` のみ残す。bind_list の string モード
(block が String を返す)と managed template モード(`template:` kwarg)も
廃止。残るのは template node モード(`Template.new(node)`)のみ。

## 5.2 背景

旧設計には list 描画と HTML 構築で多数のモードがあった:

- bind_list 4 モード(string / managed-template / template-node / `template:` kwarg)
- HTML helper による builder DSL (`HTML(:li, "text", class: "x")`)
- `<template data-template="X">` の外部 template 仕組み

すべて「runtime canonical 化と data-each の inline body 機能」で **大部分が
data-each で代替可能** になった。

## 5.3 判断の rationale

- canonical を data-each に絞ることで mental model が単純化
- spec が短くなり、新規利用者が "どう書くか" を迷わない
- HTML helper を維持する保守コストが消える
- builder DSL の "code in template" 性質も Lilac philosophy と整合的でない

## 5.4 トレードオフ

- **明確な breaking change**(旧コードは動かなくなる、Phase D で削除予定)
- 既存 example の全面書き直しが必要(todo, kanban, receipt, multipage 等)
- 「真に動的な markup 生成」escape hatch として template node モードのみ
  残るが、これは advanced 用途で日常的ではない
- HTML.escape は残るので innerHTML XSS 対策は維持

---
