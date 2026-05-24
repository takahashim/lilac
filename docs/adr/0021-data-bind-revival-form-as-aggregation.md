# 21. `data-bind` の復活と form の "集約 layer" 化(§2 部分覆し)

決定日: 2026-05-19(scanner 実装 + 関連 spec 更新)/ 本決定の正式昇格は 2026-05-20

## 問題

§2 で「input/textarea/select の declarative bind は form 経由が canonical、
汎用 `data-value` / `data-checked` は廃止」と決めた。理由は「同じことをやる
2 directive を維持する mental cost」「form 経由なら validation / touched /
dirty / error が ついで に得られる」だった。

しかし運用してみると、**コレクションの 1 要素としての input** (receipt の
行内 input、todo の編集モード、テーブルセル inline 編集、検索ボックス、
toggle 等)で form 経由が unergonomic になることが分かった:

- 行ごとに `<form>` を入れるのは semantic に違和感 (submit も send button もない)
- かといって親 form に全行の field を register すると、field 名が動的
  (`qty_1`, `qty_2`, ...) になり Symbol leak 規約 (§4) と衝突
- 結局 `bind_input refs.X, @signal` の imperative escape hatch に逃げる
  しかなく、declarative-first の Lilac 方針 (design.md §2.1) と齟齬
- 「検索ボックスやトグルを form と呼ぶ違和感」が §2 のトレードオフ節で
  既に意識されていたが、運用上は単発 toggle 1 個でも form を立てる構造
  が強制されていた

receipt example の bind_list → data-each 化作業 (2026-05-18,
`examples/runtime-only/lilac-receipt.html`) で実際にこの摩擦が顕在化。
form-spec §2 「現時点で非対応 (将来検討): 動的 collection / field array」も
**この問題の自覚的な棚上げ** として記録されていた。

## 決定

現状の「form が field を所有、field が binding を持つ」という 2 層構造を、
**直交する 3 層**に再構成する:

```
signal     値そのもの (Signal / Computed)。§2 と無関係、変更なし
  ↓ orthogonal
binding    signal ↔ DOM input の sync 機構。`<input data-bind="@qty">`
           で declarative に書ける。form と無関係に成立
  ↓ optional aggregation
form       既存の binding 群を集めて validation / submit / reset /
           base_error を提供。binding の **集約 layer** であり、binding
           それ自体ではない
```

具体には:

- **`data-bind="@ivar"` directive を導入** (§2 で削除した `data-value` /
  `data-checked` のリバイバル + 統合版)。値は signal ivar のみ、input
  type に応じて value / checked / files 等を自動選択。form の有無は不問
- **既存の `<input data-field="qty">` は form scope 内 binding の
  short-hand として温存**。`f.field :qty, ref:, initial:` 宣言は
  「signal を作って binding を貼って form に登録」の 3 ステップを 1 行で
  やる便利 API という位置付けに
- **form gem 側の API 追加は不要**。`data-bind` で結線した signal を
  form の validation に乗せたい場合は、既存の `f.field :X, source: @X`
  (§10) がそのまま使える。3 経路 (`data-bind` 単独 / `f.field` +
  `data-field` / `f.field` + `source:`) で完全カバー、API surface 増加なし
- field array 問題は「field を `data-each` で動的に並べる」ではなく
  「各行を per-row 子 component で表現し、その component 内で `data-bind`
  + ローカル signal を持つ」として解決。さらに踏み込んで「item に Signal
  を nest して per-row component すら不要」という path は §16 の bare ident
  拡張で確定済み (`data-bind="qty"` で iteration item の Signal field を bind)

## 利用者の判断基準

| 必要なもの | 書き方 |
|---|---|
| DOM 結線だけ (form features 不要) | `data-bind="@X"` |
| form の validation/submit + 値が `<input>` 内 | `f.field :X` + `<input data-field="X">` |
| form の validation/submit + 値が `<input>` の外 (子 component / 外部 signal) | `f.field :X, source: @X` |

「form を使うべきか data-bind か」が **validation / submit の有無** 一問で
決まる。

## §2 との関係 (部分覆し)

§2 を **完全に否定するのではなく、適用範囲を狭める** 改定:

- §2 の「`data-value` / `data-checked` 廃止」は維持 (両者の duplication
  は依然 mental cost)
- §2 の「input binding は form 経由が canonical」は **撤回**。代わりに
  「form は binding の集約 layer であり、binding 自体は data-bind が canonical」

§2 が完全に覆ったわけではなく、「form を中心に据える」一文だけが「form は
集約 layer に位置を譲る」に refine された。

## 影響

- **declarative coverage の拡大**: 検索ボックス / toggle / コレクション内
  input が `<input data-bind="@X">` の 1 directive で書ける。imperative
  `bind_input` への退避が要らなくなる
- **form gem の責務純化**: 「validation / submit の orchestration」が中心、
  「input ↔ signal sync」という低レベル仕事は data-bind / bind_input の
  共通レイヤに降りる
- **form gem の必須性は変わらず**: form-spec §1 の「form gem は core 機能」
  方針は維持。validation / submit の declarative API は form 経由が唯一
- **directive-spec §6.2** に data-bind が canonical として定義済み (§16
  の bare ident 拡張と組み合わせ可能)
- **decisions §16 と組み合わせ**: `data-each` 内の `<input data-bind="qty">`
  で iteration item の Signal field を per-row 子 component なしで bind 可能

## 反映先 spec

- 本 § が SSOT
- `lilac-directive-spec.md` §3 / §5 / §6.2 / §8 に data-bind の文法が
  既に反映済み (2026-05-19)
- `lilac-form-spec.md` §1 / §2 / §11.8 / §12 に「form は集約 layer」と
  3 経路 (data-bind / data-field / source:) の位置付けを反映 (本決定昇格と同時)
- `lilac-design.md` §4.5 を「form を中心に据える代償」から「form を集約
  layer に位置付けた帰結」に更新 (本決定昇格と同時)

## 実装

scanner / codegen / wasm_spec / examples の実装は 2026-05-18〜2026-05-19 に
完了:

- **runtime scanner**: `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb`
  に `dispatch_bind` (form-independent two-way binding) + `detect_bind_property`
  (input type による value / checked 自動選択) を追加
- **runtime compat rules**: `data-bind` と `data-field` が同一 element に
  共存したら build/runtime とも raise (`compat_rules.rb` SSOT pair)
- **CLI codegen**: `cli/lib/lilac/cli/codegen.rb` 内 `data-bind` directive
  対応、ivar / bare_ident 両形を emit
- **wasm_spec**: `runtime/mruby-lilac-directives/wasm_spec/test_directive_bind_runtime.rb`
  でランタイム挙動を網羅
- **example migration**: `examples/runtime-only/lilac-receipt.html` の
  line-row input を `data-bind` 化。2026-05-19 に §16 bare ident で
  さらに簡素化 (per-row 子 component 不要に)

decisions への昇格は spec 反映が遅れていたため 2026-05-20 の本決定タイミングで
最終確定。

---
