# 13. metaprogramming(`instance_variable_*` 等)を極力使わない

## 13.1 判断

`instance_variable_get` / `instance_variable_set` / `instance_eval` /
`class_eval` 等の reflection API は、**Lilac 全 gem を通じて極力使用しない**。
やむなく使う場合は **1 箇所に集約**(call site が散らからないようにする)。

現在の例外:
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_evaluator.rb`
  の `Evaluator#lookup_ivar` 1 箇所のみ `@host.instance_variable_get(value.ivar_sym)`
  を呼び出す。`@ivar` 形式の directive 値(`data-text="@count"` 等)を
  resolve する技術上の必然(後述 §13.3)

## 13.2 背景

`data-text="@count"` のような directive 値の `@ivar` 表現は、HTML 文字列
から runtime で動的に instance variable を解決する必要があり、Ruby の
標準的な方法は `instance_variable_get` のみ(`instance_eval` も同等の
reflection、回避不可)。

一方、Lilac は多くの箇所で reflection を使わずに済む設計を選択している:
- Signal / Computed は明示的な `.value` API(reflection なし)
- Form#field / Form#button は Hash 登録(reflection なし)
- Component の lifecycle hook は override + super(reflection なし)
- Lilac::Props は class-level `@prop_declarations` を method dispatch
  で walk(`instance_variable_get` を class に対して使わず、method 経由)

このため reflection の使用箇所を **明示的に決定として記録**し、新規追加時は
spec / review で必ず議論する習慣を作る。

## 13.3 判断の rationale

- **意図的に設計された情報隠蔽を破壊する**: クラスが `private` / instance
  variable / `attr_reader` 未公開等で **意図的に外部から隠している状態**
  に対し、reflection は「外から強引に触れる手段」を提供してしまう。
  `instance_variable_get(:@foo)` は `@foo` が public な API として宣言
  されていない事実を無視する。これにより:
  - クラスの内部実装(ivar 名、private method 名)が **暗黙の public API
    に格上げ**されてしまい、リファクタリングの際に「外から名前で叩いて
    いるコードがあるかもしれない」という不安が常に残る
  - クラスの設計者が「ここは public」「ここは隠す」と決めた境界が、
    reflection ユーザの便宜で **silently 上書き** される
  - encapsulation を前提にした recovery(将来の名前変更、内部構造変更)
    が困難になる
- **可読性**: `host.foo` より `host.instance_variable_get(:@foo)` は意図が読みにくい。
  reflection は「マジック」とみなされ、メンタルモデル化が難しい
- **型安全性 / 静的解析**: reflection 経由のアクセスは LSP / Sorbet 等の
  static tooling から見えない。grep / IDE の "Find Usages" にも引っかからない
- **mruby 互換性**: mruby の `mruby-metaprog` gem は default では含まれるが、
  ビルド variant で除外する可能性に備える(min variant の縮小余地)
- **Lilac の方針との整合**: directive 値の grammar は `@ivar` / `it.field` /
  method 名等の **bare identifier 限定**(§3 directive 文法厳格化)で、
  reflection は「ユーザに reflection を書かせない」設計を支えている。
  internal 実装も同じ規律で metaprog を控えるのが筋
- **集約による影響範囲の最小化**: 1 箇所に閉じ込めれば、将来 mruby 側で
  `instance_variable_*` が deprecate される / 別 API に置き換わる場合の
  修正コストが極小化

## 13.4 トレードオフ

- **`@ivar` directive 文法の維持コスト**: 完全に metaprog free にするには
  user-facing API の breaking change(`attr_reader` 必須化、名前付き signal
  登録、別 syntax 等)が必要で、現実的でない。1 箇所の reflection を許容
  することで `@ivar` の自然な書き心地を維持
- **layering の不完全さ**: directives gem 内に reflection が残る。core
  (mruby-lilac)からは消えているが「framework 全体として metaprog free」
  ではない
- **「ここだけ例外」の運用負担**: 新しい reflection が紛れ込んだ際に PR
  review / codereview スキルでの検出が必要

## 13.5 ステータス

確定済み。reflection の使用箇所は次に集約 (2026-05-18 時点):

| 場所 | 用途 | 種類 |
|---|---|---|
| `lilac_directives_evaluator.rb` `Evaluator#lookup_ivar` | `@ivar` directive 値の resolve | `instance_variable_get` |
| `lilac_component.rb` Component class method `prop` | prop accessor (`instance.X`) の auto-define | `define_method` |
| `lilac_component.rb` Component class method `prop` 内の生成 method | `@X` Signal を `.value` で返す | `instance_variable_get` |
| `lilac_component.rb` `Component#install_prop_ivars!` | `prop` の Signal を `@NAME` ivar に projection | `instance_variable_set` |
| `lilac_component.rb` `Component#update_prop` | parent → child の prop signal update (row reuse) | `instance_variable_get` |
| `lilac_component.rb` `Component#validate_prop_ivars_not_overwritten!` | setup での `@NAME =` reassign を identity 比較で検出 | `instance_variable_get` |
| `lilac_router.rb:142` | router DSL の `instance_eval(&block)` | `instance_eval` |

P2 で props 機構が `prop` = ivar 宣言 + auto-defined accessor + auto-init Signal
を兼ねるようになったため、Component 側の reflection 使用が増えた。すべて
**Component の lifecycle hook (`prepare_setup_phase` / `mount`) または `prop`
DSL の class context** に閉じている — user code が ivar 名で reflection を
書く必要はない。

新規に `instance_variable_*` / `instance_eval` / `class_eval` 等を追加する
PR は、本 § に追記または例外の正当化を spec で議論することを必須とする。

---
