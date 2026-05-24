# 1. Runtime canonical 化(Phase 0〜4 既決)

## 1.1 判断

ランタイムが directive 解釈の **canonical** で、CLI codegen は **optional
な最適化レイヤ** とする。

## 1.2 背景

旧設計では CLI(`lilac build`)が `.lil` ファイルを HTML + Ruby に変換し、
runtime は変換後のコードを実行するだけだった。これだと:

- CLI 経由しないと宣言的 directive (`data-text="@msg"` 等) が動かない
- 「Ruby + HTML を書いてブラウザで開く」だけでは動かない
- README リードの主張("Templates stay as valid HTML5 with `data-*` directives")
  が半分嘘になる

## 1.3 判断の rationale

- **ビルド不要で動く** ことが Lilac の他フレームワークに対する固有の強み
  (Vue / React / Svelte はビルド前提)
- **入門コスト** が圧倒的に下がる(教育、CodePen 共有、デモ作成)
- **CLI の役割は静的検査と最適化** に絞れる(canonical な仕様は runtime)
- 性能影響は無視できる(release ビルドで brotli +9KB 程度の検証済み)

## 1.4 トレードオフ

- runtime バンドルが directive scanner 分大きくなる(~30KB raw、~9KB brotli)
- mount 時に DOM 走査コスト発生(微秒オーダー)
- CLI の existence rationale が「optimization」に限定される
  (要らない人にとっては不要)

---
