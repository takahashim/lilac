# 31. directive binding の canonical を scanner に統一(ADR-0017 axis A を覆す)

決定日: 2026-05-29

## 問題

[ADR-0017](./0017-codegen-canonical-scanner-grammar-only.md) は 2 軸を決めた:

- **axis A**: binding 経路の canonical を **codegen** に統一。scanner gem は
  grammar reference + `codegen:off` escape hatch
- **axis B**: directive grammar の SSOT 構造(`Lilac::Directives::*` の
  host↔runtime diff-0 pair)

`cli/lib/lilac/cli/build/` の責務整理を進める中で、axis A が codegen を選んだ
4 論拠のうち **3 つが現在の実装実態では失効している**ことが分かった。前提として
**`:compiled` runtime に compiler は積まない**(`.rb` → `.mrb` は build 時のみ)
は不変だが、scanner は属性**文字列**を pre-compiled mruby で解釈するだけで
compiler を要さないため、この前提は scanner-canonical を妨げない。

### ADR-0017 axis A の 4 論拠の再評価

| ADR-0017 の根拠 | 再評価 | 根拠 |
|---|---|---|
| (1) data-each `tagName of null` バグ | ❌ 失効 | codegen が抽出した HTML に scanner も走らせた**二重処理の artifact**。scanner 単独・in-place row なら起きない |
| (2) binding 二重発火 | ❌ 失効 | codegen と scanner の併存が原因。単独経路なら無い |
| (3) grammar duplication (diff-0 pair) | △ 残る(axis B として維持) | host lint (`cross_ref_linter`) が grammar parse を使うので、`value/grammar/class_parser` の host↔runtime 二重は scanner-canonical でも残る |
| (4) bundle size(scanner を `:compiled` から外せる余地) | ❌ 失効 | scanner gem は **既に `:compiled` wasm に linked**(package の `register_directive` 用)。除外レバーは行使されておらず、package 対応のため除外も不可 |

加えて、codegen 生成コードも**毎 mount で scanner を呼んでいた**
(`scan_extensions`)。scanner の instantiation + DOM walk は codegen mode でも
既に発生しており、codegen は「その上に焼き込み呼び出しを足す」差分でしかない。

## 決定

**binding 経路の canonical を scanner に統一する**(ADR-0017 axis A を覆す)。
axis B(grammar SSOT 構造)は host lint が依存するため維持する。

- CLI の codegen 層を**削除**: `build/codegen.rb`(622 行)/ `build/form_extension.rb`
  / `directives/value_codegen.rb` / `directives/grammar_extra.rb`
- `TemplateAST` の data-each synthetic template 抽出 + `<li data-each>` の
  空洞化を**廃止** → builder は row を **in-place で出力**(= ノービルドと同じ
  shape)。`TemplateAST` の directive 収集自体は lint のため残す
- `:full` / `:compiled` / ノービルドが**完全に同一の binding 経路**(wasm 内蔵
  scanner が mount 時に DOM walk)に収束
- `c.codegen` config option を撤去(`:auto` / `:off` の分岐自体が消滅)

これは「`c.codegen = :off` に切り替える」だけでは**ない**。builder の row 抽出
(`<template data-template>` 化)が codegen mode に関わらず走っていたため、
builder の row 出力を in-place 化する変更が必須だった。

ADR-0001(runtime canonical)を最も忠実に実現し、ADR-0029 / 0030(ノービルド
世界観)とも一直線になる。decisions §17 / ADR-0017 の「binding 経路は codegen が
canonical」は本 ADR で「**binding 経路は scanner が canonical**」に読み替える。

## rationale

- **3 論拠の失効**: 上表の通り、codegen を正当化していた bug 回避 / 二重発火 /
  bundle size のうち、bug と二重発火は **codegen+scanner 併存の artifact** で
  あり単独経路では構造的に消滅する。bundle size レバーは package 対応のため
  そもそも行使不可
- **perf(唯一残った論拠)は実機計測で codegen 優位を否定**:
  300-row data-each × 行内 4 directive (data-text / data-class / data-on /
  data-attr) の fixture を実 Chrome 148 で render-complete 計測:

  | 経路 | mount (300 rows) |
  |---|---|
  | scanner-canonical | **277.3 ms** |
  | codegen | 323.7 ms |

  scanner が ~14% 速い。codegen は (a) inline script が大きく parse コスト増、
  (b) named-template clone path が per-row で走るため。差分の「per-row 属性
  parse + dispatch」純増は、codegen 側の script parse + clone コストに相殺される
- **棄却した代替**: 案 B(IR/manifest-canonical)はノービルドが CLI 不在で IR を
  生成できず full scanner も必要 → 二重実装で複雑度増。案 C(target 別 canonical)
  は divergence が増えるだけ。いずれも scanner が既に常駐する以上メリット薄

## トレードオフ

- mount 時に毎回 DOM walk + 属性 parse が走る(事前焼き込みは無い)。ただし上記
  perf 計測の通り、実測では codegen より速く、許容外ではない
- grammar の host↔runtime 二重(diff-0 pair)は axis B として残る。host lint が
  grammar parse を使う以上これは codegen 廃止後も不可避
- `value_codegen.rb` / `grammar_extra.rb` の build-time-only helper / predicate
  (`reactive_read` / `class_name?` / `ref_ident?` 等)は consumer ごと消滅

## 影響

- `cli/lib/lilac/cli/build/` が大幅縮小(codegen.rb 622 行ほか計 4 ファイル削除)
- `:full` / `:compiled` / ノービルドの dist HTML が data-each row を in-place で
  保持(`<template data-template="lil-each-*">` / `bind_template_hook` が消滅)
- form directive(`data-field` 等)は runtime form gem の `Scanner.register`
  handler が wiring。CLI 側は directive 収集(`TemplateAST` の組込み pattern)と
  lint のみ担当

## 実装

- 削除: `cli/lib/lilac/cli/build/codegen.rb` / `form_extension.rb`、
  `cli/lib/lilac/directives/value_codegen.rb` / `grammar_extra.rb`
- `cli/lib/lilac/cli/build/template_ast.rb`: `extract_each_body` の unlink /
  synthetic template 化を停止(row in-place)。`data-field` を組込み
  `DIRECTIVE_PATTERNS` へ移設(旧 form_extension の `register_directive` 相当)
- `cli/lib/lilac/cli/build/{component_scripts_assembler,bundle_asset_writer}.rb`:
  codegen 呼び出しを除去し user_script のみ emit
- `c.codegen` 撤去: `config.rb` / `config_loader.rb` / `build_context.rb` /
  `builder.rb`
- 既存機構の再利用(無改修): runtime scanner の in-place data-each
  (`lilac_directives_scanner.rb` `dispatch_each`)、`bind_template_hook` の
  scanner fallback(`lilac_component.rb`)、form runtime handler
  (`lilac_form_directives.rb`)
- 検証: `cd cli && bundle exec rake test`(394 runs green)、`make test-wasm-rb`
  (71/71 spec files pass)、7guis を実 Chrome で golden path 確認
  (Counter / CRUD / Timer の data-each・form・event)
