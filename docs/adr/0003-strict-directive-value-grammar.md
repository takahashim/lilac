# 3. directive 値の文法を厳格に保つ

## 3.1 判断

directive 値は **identifier 参照のみ** を許す。`@ivar`、bare ident、
method 名、登録名。任意 Ruby 式は禁止。

> **履歴 (2026-05-19 追記)**: 当初例示していた `it.field` 構文は
> [ADR-16](./0016-drop-it-path-and-bare-ident-scope.md) で全廃され、
> iteration item field の参照は bare ident
> (`<span data-text="title">` の `title`)に統一された。本 ADR の
> 原則(任意式禁止 / identifier 参照のみ)はそのまま維持。

## 3.2 背景

JSX / Vue / Alpine は template 内に任意 JS 式を書ける:
```jsx
<div className={errors.email ? "invalid" : "valid"}>
```

これは柔軟だが:
- 「template でロジック」の温床(複雑な式が markup に混ざる)
- template と Ruby のどちらに logic があるかが曖昧になる
- LSP / debugger が template 内式を扱う必要が出る
- escape / interpolation で XSS バグの温床

## 3.3 判断の rationale

- Ruby 開発者は Ruby 側で logic を書きたい(template は markup の場)
- "Templates are configuration, not code" の純度を保つ
- spec / parser / lint が単純に保てる(任意式の対応は parser を肥大化させる)
- template と Ruby の分離が明確 = 教育コストが低い

## 3.4 トレードオフ

- 「テンプレで `@count + 1` と書きたい」場面でも `@count_plus_one = computed { @count.value + 1 }` と Ruby 側 ivar を増やす必要あり
- 派生 computed が多い form 等で **verbose** になる(これに対応するのが
  `data-field` compound directive のような対症療法)
- 利用者は最初に「式を書きたくなる」誘惑と戦う必要(教育)

---
