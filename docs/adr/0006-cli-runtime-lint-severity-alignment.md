# 6. CLI と runtime の lint severity 整合

## 6.1 判断

- **runtime が raise する違反は build 時も error**(例: undeclared
  `data-button`、directive 文法エラー、banned `data-attr-X` 属性)
- **runtime が warn / auto-recover する違反は build 時も warning**
  (例: undeclared `data-field` は runtime で auto-register、undeclared
  `data-form` は auto-create、form gem 未ロード時の `data-field` は silent
  skip — いずれも warning)

判断のキーは「runtime がエラーで止まるかどうか」。runtime が auto-X で
recover する違反を build error にすると、書いた通り動く HTML が build を
通らなくなり原則から外れる。

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

2026-05-18 時点で実装完了。`CrossRefLinter` が form / field / button の
cross-reference を check し、`data-button="X"` で `f.button :X` 未宣言の
場合は **build error** (runtime raise との severity 一致)、`data-field` /
`data-form` 未宣言は warning (runtime auto-register / auto-create に
合わせる)。詳細は `lilac-form-spec.md` §13。

---
