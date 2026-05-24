# 6. CLI と runtime の lint severity 整合(ADR-22 で部分覆し)

## 6.1 判断

- **runtime が raise する違反は build 時も error**(例: directive 文法
  エラー、banned `data-attr-X` 属性。**当初は undeclared `data-button`
  も含まれていたが ADR-22 で削除**)
- **runtime が warn / auto-recover する違反は build 時も warning**
  (当初は undeclared `data-field` / `data-form` も含まれていたが
  **ADR-22 で削除**。現在はそれらの CLI 側 check 自体が存在しない)

判断のキーは「runtime がエラーで止まるかどうか」。runtime が auto-X で
recover する違反を build error にすると、書いた通り動く HTML が build を
通らなくなり原則から外れる。

> **注 (2026-05-22 追記)**: 本 ADR の form 関連 lint(`data-button` 未宣言
> の build error / `data-field` / `data-form` 未宣言の warning)は
> [ADR-22](./0022-drop-form-cli-build-time-lint.md) で **全廃**された。
> 理由は「form gem の Ruby AST 解析を CLI が hardcode していたのが form
> 分離の最大障壁だった」「runtime 側で同等検出ができている (runtime
> canonical 原則)」。本 ADR の **severity 整合原則** はそのまま維持され、
> その実現手段が「CLI が独自検証」から「runtime に委ねる」に変わった形。
> directive 文法エラー / banned `data-attr-X` の build error は引き続き
> 有効。

## 6.2 背景

旧設計では「CLI lint は warning、runtime は raise」のような **severity
gap** が発生しがちだった。build が通っても deploy 後即死する状況が
起きうる。

## 6.3 判断の rationale

- build 時に検出できる correctness violation を warning に留める理由はない
  (build error にしないと意味がない)
- severity が一致しないと「lint は通ったのに本番で raise」がデバッグ困難
- runtime severity policy を canonical として、CLI lint がそれに従う

## 6.4 トレードオフ

- CLI のエラー数が増える(意図的)
- 段階的移行(deprecated → warning → error)の余地は残す(個別 issue)

## 6.5 ステータス

2026-05-18 に form 関連 lint を含めた severity 整合を実装完了
(`CrossRefLinter` が form / field / button の cross-reference を check し
`data-button` 未宣言を build error、`data-field` / `data-form` 未宣言を
warning として扱っていた)。

**2026-05-22 に [ADR-22](./0022-drop-form-cli-build-time-lint.md) で form
関連 lint を全廃**。現 `cross_ref_linter.rb` の check 範囲は次に限定:

- signals (`@ivar` 未宣言 → warning)
- methods (`data-on-X="undefined_method"` → warning)
- each-without-key (`data-each` の `data-key` 欠如 → warning)
- reserved ref names (`data-ref="lilN"` の予約名衝突 → warning)
- dead signals / dead methods (宣言したが参照されていない → warning)

build error を立てる check は **ゼロ件** (= ADR-22 で意図的にそうなった)。
directive 文法 / banned `data-attr-X` の build error は codegen 側で
引き続き raise されるため、本 ADR の severity 整合 **原則** は守られている。

---
