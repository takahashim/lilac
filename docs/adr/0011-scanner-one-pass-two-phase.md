# 11. scanner one-pass + 2-phase processing

## 11.1 判断

scanner は DOM を **one-pass で走査** して全 directive を record list に
収集し、**data-field / data-button を先に処理してから他 directive を
処理** する(internal 2-phase processing)。

## 11.2 背景

`<input data-field="text">` が DOM 上で `<p data-text="@upper">`
(computed が `form[:text].value.upcase` を読む)より **後** に出現する
ケースがあり得る。DOM 順に逐次 wire する設計だと、`@upper` 評価時点で
`form[:text]` が未定義になり壊れる。DOM 順序に依存する仕様は壊れやすい。

## 11.3 判断の rationale

- **one-pass DOM walk**: O(N) を維持、two-pass DOM walk より約半分のコスト
- **2-phase processing**: field/button の確定を他 directive より先に行う
  ことで、DOM 順序非依存性を保証(利用者は「`<input>` が `<p data-text>`
  より前か後か」を気にしなくてよい)
- form の auto-create(§8)も phase 2 で発生するので「Ruby ゼロ宣言 +
  HTML だけ」のコンポーネントが成立する
- Phase 1 で record list を全部作るので、エラー(`data-form` を非-form に
  書く等)も走査中に全件検出して報告できる

## 11.4 トレードオフ

- record list を一時的に保持するメモリオーバーヘッド(directive 数オーダー)
- 走査と wiring の 2 ステップに分かれるので実装の mental model がやや複雑
  (spec doc で説明が必要)
- ただし利用者が「DOM 順序を気にしないで書ける」メリットは大きい

## 11.5 ステータス

実装済み。form-spec §18.4 に反映。

---
