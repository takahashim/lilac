# 8. form scope の決定規則

## 8.1 判断

form scope は **自 component subtree 内の ancestor `<form>` 要素** で
決まる:

| 構成 | scope |
|---|---|
| `<form data-form="signup">` あり | `:signup` named scope |
| 素の `<form>`(data-form 無し)あり | `:default` scope |
| `<form>` 要素無し、`<input data-field>` のみ | 自コンポーネントの default form |
| `<div data-form="X">` 等の非-form 要素 | `Lilac::Error` raise |
| 同 component 内に素の `<form>` 複数 | `:default` 衝突で raise |

ancestor walk は **自 component subtree 内のみ**(component 境界で停止、
他コンポーネントの subtree は scan しない)。form は常に自 component に
所有される(host の曖昧さなし、orphan signal なし、grep で field の
所在が完全に追える)。

form の Ruby 宣言(`form do |f| ... end`)が無くても、scanner が auto-create
するので「Ruby ゼロ宣言 + HTML だけ」のコンポーネントが成立する。

## 8.2 背景

form 抽象を導入する以上、「どの form にこの field が属するか」を答える
必要がある。素朴な選択肢:
- HTML native の `<form>` を尊重する → submit/validation の native 機能と整合
- 任意の要素で scope を作れるようにする → 柔軟だが意味が曖昧
- DOM 全体を walk して `<form>` を探す → encapsulation を破壊

## 8.3 判断の rationale

- **`<form>` 要素を基準にする**: HTML living standard と整合、`<button type="submit">`
  の native submit が直接 wire できる、`form=""` 属性(HTML 既定の form
  association)との semantic 衝突がない
- **subtree-only walk**: component encapsulation を維持(Lilac の他 directive
  `data-text` 等も自 component scope で `@ivar` を解決するのと整合)。
  cross-component sharing が必要なら §10 の `source:` パターンで明示橋渡し
- **非-form 要素を禁止**: scope の意味を曖昧にしない。submit を発火させ
  たくないだけなら `:submit` handler を書かなければ良いので非-form scope を
  作る実益が薄い
- **素の `<form>` 多重時 raise**: silent fallback よりも明示的なエラーで
  typo / 設計ミスを検出。明示的に区別したい場合は `data-form="..."` で命名

## 8.4 トレードオフ

- cross-component で form を共有したいケースは spec 外(§10 の `source:`
  パターンで橋渡し)
- 同 component 内に純粋に「何も付けていない `<form>`」を 2 つ並べる書き方が
  できない(片方を `<form data-form="X">` にする必要)
- HTML だけ書くシンプル user は「`<form>` の中に input を入れる」HTML 知識が
  必要(ただしこれは HTML 標準そのものなので学習負担とは言いにくい)

## 8.5 ステータス

実装済み(scanner)。form-spec §11.2 / §11.2.1 / §18.4 に反映。

---
