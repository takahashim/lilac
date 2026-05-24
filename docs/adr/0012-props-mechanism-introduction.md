# 12. Props 機構の導入 (superseded in part by §14)

## 12.1 当時の判断 (P1)

`data-prop-*` 属性経由で component に declarative configuration を渡す
**props 機構** を Lilac に追加する:

- `prop :NAME, TYPE [, default: VALUE]` で component class が宣言
- `props.NAME` でアクセス(mount 時に固定された値)
- 対応 type は **String / Integer / Float / Boolean** の 4 つ
- attribute 名は kebab、Ruby 名は snake(`data-prop-max-length` → `props.max_length`)
- 必須 prop の attribute 無し → mount 時に error として通知
  (error_boundary / `Lilac.logger.error` 経由、page 全体は continue)
- 型変換失敗 → 同上(`Integer("abc")` 等)
- Boolean は **`"true"` / `"false"` + presence shortcut** を許容、`"yes"` /
  `"1"` / `"on"` 等も error として通知
- 未宣言 `data-prop-X` 属性は dev_mode で warn(typo 検出)
- Phase 1 は **read-once**(mount 時固定)、reactive props は将来検討

詳細は [`lilac-props-spec.md`](./lilac-props-spec.md)。

## 12.2 背景

Lilac component は現状 **「設定値を外部から渡す機構」が無い**。同じ component
class を異なる設定で複数 instance 化したい場合(例: LabeledInput を
email / password / phone 用に複数使う、Counter を初期値違いで配置)、
利用者は以下のいずれかを強いられていた:

- 設定値ごとに subclass を作る(冗長、再利用にならない)
- 親 component から `refs.X.component.foo = ...` で setup 後に書く(順序問題、
  encapsulation 違反気味)
- そもそも component にしない(markup 重複)

React / Vue / Solid 等の主要フレームワークは props を第一級に持つので、
この摩擦は無い。Lilac の他原則(HTML 内ロジック禁止、`data-*` ベース
declarative)と整合する形で props 機構を導入する必要があった。

## 12.3 判断の rationale

- **`data-prop-*` 属性ベース**: Lilac の他 directive と同じ流儀、HTML 標準に
  乗る、scanner が読みやすい
- **4 type に絞る**: HTML 属性値は文字列なので primitive のみで実用上ほぼ
  カバーできる。Hash / Array は複数の primitive prop に分解する慣行で対応
  (spec を小さく保つ)
- **`Integer(...)` / `Float(...)` 厳密変換**: `to_i` の silent fallback
  (`"5x"` → `5`)を避けて typo を検出。Lilac の他 directive と同じ
  fail-fast 方針
- **Boolean ハイブリッド規約**: HTML 標準の `<input disabled>` 慣行を尊重
  しつつ、`"yes"` / `"1"` 等の曖昧表現を禁止(明示的 truth value のみ)
- **`props.X` API**: Stimulus の `this.XValue` より短く Ruby 慣行に近い。
  `props` namespace で「外部入力」と読める、補助メソッドを足しやすい
- **必須 prop は default 無しで宣言**: silent 0/nil fallback よりエラーで
  検出する方が安全(Lilac の他 directive 同様、ergonomics は warn だが
  correctness は raise)
- **mount 時 read-once**: 実装単純、MutationObserver 不要、99% のユース
  ケースをカバー。reactive opt-in は将来追加可能
- **kebab → snake auto-convert**: HTML と Ruby の慣行の差を吸収、Rails
  / Stimulus と同じ流儀
- **form と独立**: props は declarative configuration、`source:` は reactive
  value flow、直交する concern を分けて設計

## 12.4 トレードオフ

- **HTML 属性数が増える**: 設定項目が多い component(`LabeledInput` で 4〜5 個)
  は HTML が長くなる(`data-prop-X="..."` が 4〜5 回繰り返し)。React の
  `<X a="..." b="..." />` より文字数は多い
- **Hash / Array 渡しが困難**: 複雑な config を渡したい component(例:
  table の column 定義)は props だけでは表現困難。将来 JSON parse 等を
  検討する余地あり
- **mount 後変化しない**: Phase 1 では reactive props 無し。動的に props を
  変えるユースケース(SPA の route 変更で設定が変わる等)は別途 signal
  経由で扱う必要
- **`Lilac::Boolean` sentinel module**: Ruby に組み込み Boolean class が
  無いので独自 sentinel を使う(`prop :x, Lilac::Boolean`)。利用者が
  「`Boolean` が無い」事実を覚える必要

## 12.5 ステータス

Phase P1 実装済み(`runtime/mruby-lilac/mrblib/lilac_props.rb`)。
その後の拡張(`@X` Signal auto-init、public reader、row reuse 時の
`update_prop`、値式サポート等)は §14 で判断を更新した。
reactive props (P3) / change callback (P4) は将来 phase、実需に応じて追加。
詳細は `docs/lilac-props-spec.md` 参照。

---
