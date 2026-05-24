# 9. `<input form="...">` 属性の扱い

## 9.1 判断

`<input form="...">` 属性は Lilac scope 解決には **使わない**。検出時は
`Lilac.logger.warn` で 1 回警告して属性自体は無視(native browser 機能は
そのまま動く)。

## 9.2 背景

HTML living standard には `<input form="<form-id>">` で離れた `<form>` と
関連付ける機能がある(form owner = その id を持つ form)。Lilac の form
scope 規則を ancestor walk だけにすると、この HTML 標準機能との関係を
どう扱うか決める必要がある。

## 9.3 判断の rationale

- `form=""` を Lilac scope に使うと **document 任意位置から任意 form に
  書き込み可能** になり、§8 の subtree-only 原則と矛盾、component
  encapsulation を完全に破壊
- 入れ子コンポーネントで足りないケースは `source:` 経由の明示橋渡しで
  カバーできる(§10)
- warn を出すのは「ユーザが期待する Lilac 挙動と実際の挙動が違う」ことを
  早期に知らせるため
- 属性自体は browser に渡す(native form submit には参加させる)ので
  HTML 機能は壊さない

## 9.4 トレードオフ

- `form=""` で離れた要素を form に組み込む既存の HTML pattern は Lilac
  state には乗らない(native submit のみで処理される)
- ただし Lilac で同等のことをしたければ component を入れ子にして `source:`
  で橋渡しする方が encapsulation を維持できる

## 9.5 ステータス

実装済み。form-spec §11.2.2 に反映。

---
