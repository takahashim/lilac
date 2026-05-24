# 22. Form 関連の CLI build-time lint を廃止 (§6 部分覆し)

## 22.1 判断

`cross_ref_linter` の **form 関連 cross-reference checks**
(`data-form` / `data-field` / `data-button` を `form do |f| f.field :x
end` 系の Ruby 宣言と突き合わせる lint) と、それを支える
`script_analyzer` 側の form block tracking
(`@declared_forms` / `@declared_fields` / `@declared_buttons`、
`with_form_block_frame` / `record_field_or_button_declaration` 等)
を全廃する。Form 直交 lint は runtime に一本化する。

## 22.2 背景

§6 で CLI と runtime の lint severity 整合を取り、`data-button` 未宣言を
build error 化していた。同時に form 関連の AST 解析が
`script_analyzer.rb` (~80 行) + `cross_ref_linter.rb` の
`FORM_REF_CHECKS` テーブルとして CLI 側に積み上がっていた。

その後 form 分離 (form gem を真の plug-in として core / CLI から
切り離す方向) の検討で次が判明:

- form 関連の lint は runtime 側で **すでに同等の検出ができている** —
  `data-button` 未宣言は runtime が `Lilac::Error` を raise、`data-field`
  未宣言は auto-register + `Lilac.logger.warn` を出す
- CLI 側 form 解析は **form gem の Ruby 構文 (`form do |f| f.field`) を
  Prism マッチで認識** しており、form gem の API 形に hardcode 依存
- これは form 分離の **最大の障壁**。CLI に「form を知らない」状態を
  作るには、まずこの依存を消す必要がある
- そのまま残して plug-in 化するなら `script_analyzer` に extension 機構を
  足し form gem 側に visitor を持たせる必要があり、現時点の plug-in 需要
  (1 gem) に対して過剰設計

## 22.3 rationale

- **runtime が canonical** (§1) の原則をそのまま適用: form の挙動について
  runtime が単一の真実、CLI は無理に追わない。これまでの form lint は
  runtime / CLI の二重実装で、§1 と整合しない箇所だった
- 「`lilac-cli` は optional な最適化レイヤ」(§1 / README) という建付け上、
  build-time 早期エラー化は **必須ではなく nice-to-have**。runtime 側の
  エラーメッセージで実用上は十分
- 削除により `script_analyzer.rb` は 367 → ~290 行、`cross_ref_linter.rb`
  は FORM_REF_CHECKS テーブル + 関連メソッド ~70 行が消える
- form 分離 (将来の作業) において CLI 側の form-specific コードは
  template_ast / codegen / directive にもあるが、**最も深い結合 (Ruby AST
  解析) を先に除去** することで残作業の見通しが立つ
- 将来 lint を再導入するなら 3 経路 (案 A: register API で form plug-in
  に持たせる、案 B: wasmtime-rb 経由の runtime introspection、案 C:
  `lilac doctor` / `lilac lint --strict` 等の独立コマンド) のいずれかで
  対応可能。**本決定はそのいずれも閉ざさない** (build artifact / runtime
  挙動は不変)

## 22.4 トレードオフ

- **失うもの**: `f.button :submitt` のような typo を build 時に検出する
  機能。component mount 時の `Lilac::Error` メッセージで代替されるため、
  ユーザは初回 interaction で気づく形になる
- **CI 影響**: `lilac build` の exit code を lint signal として CI で
  使っていたチームには regression。pre-1.0 期なので CHANGELOG で
  announce する程度で十分
- **§6 との整合**: §6 は「CLI と runtime の severity を揃える」決定だが、
  本決定は「CLI で同等チェックをしない」方向。§6 の精神 (=
  runtime と CLI の振る舞いを一貫させる) は維持されており、その実現
  手段が「CLI が独自に検証」から「CLI は検証せず runtime に委ねる」に
  変わった、と捉える
- `cross_ref_linter.rb` の `Result(warnings:, errors:)` API は残す。
  現状 `errors` を立てる check はゼロだが、将来別の fatal check を
  足したくなったときに Builder 側の分岐を再配線せずに済む

## 22.5 実装

- `cli/lib/lilac/cli/script_analyzer.rb`:
  Result struct から `declared_forms` / `declared_fields` /
  `declared_buttons` フィールド削除、対応する `declares_form?` /
  `declares_field?` / `declares_button?` メソッド削除、Visitor から
  form block stack 関連 (`with_form_block_frame`, `form_block_call?`,
  `record_field_or_button_declaration`, `form_name_arg`,
  `first_symbol_arg`, `block_first_param_name`) を削除
- `cli/lib/lilac/cli/cross_ref_linter.rb`:
  `FORM_REF_CHECKS` 定数、`lint_form_ref` / `emit_form_ref_warning`
  メソッド、`lint` 内の FORM_REF_CHECKS loop を削除
- `cli/test/test_cross_ref_linter.rb`:
  form / field / button 関連の test ケース 8 件削除
- `Lilac::CLI::Directive` の `form_scope` / `field_input_ref` フィールドは
  **残す** — codegen.rb の `emit_form` / `emit_field` / `emit_button` が
  引き続き使用するため。これらは form 分離の次段階で扱う

## 22.6 後続作業

form 分離は 4 階層 (script_analyzer / cross_ref / template_ast +
codegen 文字列 / runtime directives gem の FormWiring) のうち、
本決定で最も深い階層を除去した。残る階層を扱う場合の路線:

- **Runtime FormWiring の plug-in 化** — directives gem の `Scanner` に
  `register_directive` API を作り、form gem 側に form_wiring を移動
- **CLI template_ast / codegen の plug-in 化** — 同じ register API を CLI
  にも作り、form 用 emitter を form gem 配下に移動
- いずれも本決定とは独立した別マイルストーン。本決定は単独で完結する

---
