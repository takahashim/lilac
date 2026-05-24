# 10. stateful 子 input component の form 組み込み

## 10.1 判断

typeahead / 日付ピッカー等の自前 internal state を持つ入力部品を form
field として組み込む規約:

- 子 component は `Lilac::FieldComponent` 基底クラスを継承
  (`attr_reader :value` / `initial_value` / `reset` を提供)
- 親 component は `f.field :name, source: refs.X.component` で組み込む
- `source:` は polymorphic: `FieldComponent` か生 Signal の両方を受ける
- `FieldComponent` の場合 `form.reset` が `source.reset` を自動呼び出し
- 生 Signal の場合は reset 伝播なし(field 宣言時 dev_mode warn)

## 10.2 背景

form scope を subtree-only に決めた結果(§8)、子 component の `data-field`
は親 form に登録できない。一方、stateful な入力部品(typeahead / 日付
ピッカー / リッチエディタ等)は再利用性と複雑度の観点で **component として
encapsulate したい**。「子 component が持つ state を親 form の field
として扱う」橋渡し機構が必要。

## 10.3 判断の rationale

- **encapsulation 保持**: 子 component は親 form を知らない
  (`FieldComponent` 自体が form を知らない)、親が wiring 責任を持つ
- **two-way 自然に成立**: parent の `form[:country].value = ...` 書き込みが
  child の `@value` signal に流れ、UI も自動更新(signal の reactivity)
- **JSX 系の Modular Forms (Solid) / Felte `bind:value` (Svelte) と
  同じ camp**: 明示データフロー派、現代的 fine-grained reactivity との整合
  (React Hook Form 風の DI/Context 派とは別路線)
- **polymorphic `source:`**: 基底クラス継承の有無に関わらず使える、API が
  1 つで済む
- **reset 伝播の自動化**: `FieldComponent` 基底を継承するだけで `form.reset`
  が動く、慣行が code 化される
- **子 component が form 外でも使える**: `useFormContext` 風の暗黙 DI と違い、
  子は form 依存を持たないので汎用 input としても再利用可能
- **`source:` という名前**: polymorphic 引数の語感が `value:` より自然
  (component を渡しても違和感がない)、`initial:` との直交が明確

## 10.4 トレードオフ

- 子 component に `FieldComponent` 継承を要求(mix-in module 案より制約が強い、
  ただし将来 mix-in も追加可能)
- `source:` が polymorphic(component / signal の 2 種類を判定)で内部実装が分岐
- `attr_reader :value` を持たない arbitrary な component を `source:` に
  渡すと duck-type で扱われる(`respond_to?(:reset)` 判定)、暗黙の規約
- 親に 1 行 wiring 文(`f.field :country, source: refs.X.component`)が増える。
  React Hook Form 風の DI と比較すると boilerplate がやや多い(ただし
  Solid / Svelte 流派は同等)

## 10.5 ステータス

実装済み。form-spec §3.1 / §5 / §7 / §18.2.1 / §18.6 に反映。

---
