# Lilac ドキュメント案内

このディレクトリは Lilac の設計と仕様を集約する。

## ファイル一覧

doc は **3 レイヤ**(原則 / 判断 / 仕様)に分かれ、補足としてベンダー固有の記録が 1 つ。
判断レイヤは「確定」と「未確定」で 2 doc に分離している。

### 原則レイヤ — why

| doc | 内容 | 読むべきとき | 更新頻度 |
|---|---|---|---|
| [`lilac-design.md`](./lilac-design.md) | 設計原則と意識的に受け入れた trade-off の SSOT | 「なぜ Lilac はこう設計されているのか」を知りたいとき | 原則そのものが変わる時のみ |

### 判断レイヤ — why

| doc | 内容 | 読むべきとき | 更新頻度 |
|---|---|---|---|
| [`adr/README.md`](./adr/README.md) | 確定した個別判断 (ADR) の index + ADR ファイル群 (`adr/0001-...md` 〜 `adr/NNNN-...md`)。覆された判断も `(superseded by ADR-NN)` で残す | spec を読んで「なぜここはこうなっているか」を引きたいとき | ADR 単位で追記、削除はほぼなし |
| [`lilac-proposals.md`](./lilac-proposals.md) | **未確定** の設計提案。確定したら新 ADR として昇格して削除 | 議論中の変更を把握 / 新提案を起こす前の重複チェック | 任意のタイミングで編集可 |

### 仕様レイヤ — how(現状の解説)

| doc | 内容 | 対応 gem |
|---|---|---|
| [`lilac-spec.md`](./lilac-spec.md) | Lilac core(Component / Signal / Effect / bind / bind_list / expose-lookup) | `mruby-lilac` |
| [`lilac-directive-spec.md`](./lilac-directive-spec.md) | `data-*` directive(`data-text` / `data-bind` / `data-each` / `data-on-*` 等)の文法と意味論 | `mruby-lilac-directives` |
| [`lilac-form-spec.md`](./lilac-form-spec.md) | Form gem(`data-form` / `data-field` / `data-button` + Ruby DSL) | `mruby-lilac-form` |
| [`lilac-props-spec.md`](./lilac-props-spec.md) | `data-prop-*` + `prop :X` 宣言、iteration item auto-fill 機構 | `mruby-lilac`(props) |
| [`lilac-router-spec.md`](./lilac-router-spec.md) | SPA navigation、URL を signal として扱う | `mruby-lilac-router` |
| [`fetchy-spec.md`](./fetchy-spec.md) | Fetchy HTTP client(`Widget#resource` 用) | `mruby-lilac-async` |
| [`lilac-package-spec.md`](./lilac-package-spec.md) | Package 機構: 公式 / 第三者 package の書き方・ビルド・配布・load | `mruby-lilac-directives`(register surface)|

仕様は実装に追従する形(実装が canonical、spec はそれを記述)。
spec が先行する変更フローは取らない。変更する場合はまずporposalsに書く。

## 動線

### 設計変更を入れる順

[proposals.md](./lilac-proposals.md) で議論 → 確定 → [`adr/`](./adr/) に新 ADR を追加 + 影響 spec 更新 → 原則改訂を伴うなら [design.md](./lilac-design.md) も同期

## 編集の心得

- spec は実装に追従
  - 実装変更が先、spec はそれを記述する。spec だけ変えて実装放置は NG
- ADR は積み上げ
  - 削除せず、覆すときは旧 ADR タイトル冒頭に `(superseded by ADR-NN)` をマーク。歴史が adr/ 配下で完結することが価値
- proposals は流動的
  - 議論で内容が変わってよい。却下なら削除、確定したら新 ADR ファイルとして昇格。昇格 operation は proposals.md 冒頭参照
- design.md は最少改訂
  - 原則そのものを書き換えるレベルだけ。個別判断は ADR (adr/NNNN-*.md) 側で記録する

