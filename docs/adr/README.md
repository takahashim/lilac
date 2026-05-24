# Lilac 設計判断ログ (ADR Index)

このドキュメントは Lilac の **主要な設計判断とその rationale** の **index**
です。個別の判断は同 directory (`docs/adr/`) 配下に分割保存されている
(1 判断 = 1 ファイル、ADR-NNNN 形式)。

設計原則と positioning は [`lilac-design.md`](../lilac-design.md) を参照。
ここで述べる各判断は、その原則に基づく **具体的な適用** または **既存決定の
refinement** として位置付ける。

## ADR フォーマット

各 ADR は以下のセクションで構成:

| 項目 | 内容 |
|---|---|
| 判断 | 何を決めたか(1〜2 文) |
| 背景 | なぜこの判断が必要になったか(直前の状況、問題提起) |
| rationale | なぜこの判断を選んだか(他案との比較、原則との整合) |
| トレードオフ | 受け入れたコスト、想定される副作用 |
| 実装 | 実装した場所 / phase 構成 (任意) |
| 後続作業 | スコープ外として残した項目 (任意) |
| ステータス | 着手 / 完了 / superseded by ADR-NN |

過去判断を **覆す** 場合は旧 ADR のタイトル冒頭に `(superseded by ADR-NN)` を
追加し、当該 ADR 自身は歴史として残す。新 ADR の rationale で「過去 ADR-MM の
判断を覆した」と言及する。

## 新規 ADR の追加手順

1. `docs/adr/NNNN-slug.md` を新規作成 (NNNN = 4 桁 zero-padded、`# NNNN. Title` で始める)
2. 上記フォーマットに従って本文を記述
3. 本 index ファイルの「ADR 一覧」テーブルに 1 行追加
4. 覆された旧 ADR があればそのタイトルに `(superseded by ADR-NN)` を追記

## ADR 一覧

| ADR | 判断 | 反映先 spec / 実装 | ステータス |
|---|---|---|---|
| [0001](./0001-runtime-canonical.md) | Runtime canonical 化 | `lilac-directive-spec.md` 全体 | 完了 (Phase 0〜4) |
| [0002](./0002-form-as-bind-center.md) | Form を input bind の中心機構に | `lilac-form-spec.md` §1, §11 | 完了 (Phase A〜D)、ADR-0021 で部分覆し |
| [0003](./0003-strict-directive-value-grammar.md) | directive 値の文法を厳格に保つ | `lilac-directive-spec.md` §1.1, §3 | 継続 |
| [0004](./0004-symbol-leak-and-hash-keys.md) | Symbol leak 制約と Hash キー方針 | `lilac-form-spec.md`, `lilac-spec.md` items 規約 | 随時 |
| [0005](./0005-drop-html-helper-and-bind-list-legacy.md) | HTML helper / bind_list legacy mode の廃止 | `lilac-spec.md` HTML helper / bind_list 章 | 完了 (Phase D) |
| [0006](./0006-cli-runtime-lint-severity-alignment.md) | CLI と runtime の lint severity 整合 | `lilac-form-spec.md` §13 | 完了 (2026-05-18)、ADR-0022 で部分覆し |
| [0007](./0007-input-value-auto-register.md) | `<input value>` からの auto-register | `lilac-form-spec.md` §5, §11.3.1, §11.7 | 完了 |
| [0008](./0008-form-scope-resolution-rules.md) | form scope の決定規則 | `lilac-form-spec.md` §11.2, §11.2.1, §18.4 | 完了 |
| [0009](./0009-input-form-attribute.md) | `<input form="...">` 属性の扱い | `lilac-form-spec.md` §11.2.2 | 完了 |
| [0010](./0010-stateful-input-component-form-integration.md) | stateful 子 input の form 組み込み(`FieldComponent` + `source:`) | `lilac-form-spec.md` §3.1, §5, §7, §18.2.1, §18.6 | 完了 |
| [0011](./0011-scanner-one-pass-two-phase.md) | scanner one-pass + 2-phase processing | `lilac-form-spec.md` §18.4 | 完了 |
| [0012](./0012-props-mechanism-introduction.md) | Props 機構の導入(`data-prop-*` + `prop` DSL) | `lilac-props-spec.md` | Phase P1 完了、ADR-0014 で拡張 |
| [0013](./0013-minimize-metaprogramming.md) | metaprogramming(`instance_variable_*` 等)を極力使わない | `lilac_directives_evaluator.rb` `lookup_ivar` | 随時 |
| [0014](./0014-props-p2-prop-semantics-extension.md) | Props P2: `prop` の意味拡張(ivar 宣言 + accessor + 値式) | `lilac-props-spec.md` | 完了 |
| [0015](./0015-lilac-full-bundle-size-optimization.md) | lilac-full の bundle size 最適化(browser-only + explicit allow-list + -Oz) | `build_config/lilac-full.rb`, `Makefile` | 完了 (2026-05-19、-25.3% raw / -23.0% brotli) |
| [0016](./0016-drop-it-path-and-bare-ident-scope.md) | `it.path` 全廃 + value-binding bare-ident scope + data-prop-* auto-fill | `lilac-directive-spec.md` §3 / §5 / §6.2、`lilac-props-spec.md` §7.5 / §7.6 | 完了 (2026-05-19) |
| [0017](./0017-codegen-canonical-scanner-grammar-only.md) | directive binding は codegen が canonical / scanner gem は grammar reference | `cli/lib/lilac/directives/` ↔ `runtime/mruby-lilac-directives/mrblib/` | 完了 (2026-05-19) |
| [0018](./0018-lilac-build-compiled-single-command.md) | `lilac build --target compiled` 単一コマンド deploy | `cli/lib/lilac/cli/builder.rb` + `compiled_runtime_resolver.rb` | 完了 (2026-05-20) |
| [0019](./0019-codegen-positional-lil-ref.md) | Codegen positional `lilN`(`data-ref` 注入の廃止) | `cli/lib/lilac/cli/template_ast.rb` + `runtime/mruby-lilac/mrblib/lilac_ref.rb` | 完了 (2026-05-20) |
| [0020](./0020-component-scope-rule-and-lilac-start.md) | Component scope rule の確定 と `Lilac.start` 自動化 | `cli/lib/lilac/cli/builder.rb` + `script_analyzer.rb` + `runtime/mruby-lilac/mrblib/lilac_registry.rb` | 完了 (2026-05-20) |
| [0021](./0021-data-bind-revival-form-as-aggregation.md) | `data-bind` の復活と form の "集約 layer" 化(ADR-0002 部分覆し) | `lilac-directive-spec.md` + `lilac-form-spec.md` + `lilac-design.md` §4.5 | 完了 (2026-05-20) |
| [0022](./0022-drop-form-cli-build-time-lint.md) | Form 関連の CLI build-time lint を廃止(ADR-0006 部分覆し) | `cli/lib/lilac/cli/script_analyzer.rb` + `cross_ref_linter.rb` | 完了 (2026-05-22) |
| [0023](./0023-plugin-mechanism-runtime-fallthrough.md) | Plug-in 機構: runtime canonical の延長としての runtime fallthrough | `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` + `cli/lib/lilac/cli/codegen.rb` | 完了 (2026-05-23) |
| [0024](./0024-npm-distributed-plugin-superseded.md) | Plug-in 配布形態: `lilac-compiled` core + 個別 npm plug-in(**superseded by ADR-0025**) | (歴史) | 上書き済み (2026-05-23) |
| [0025](./0025-pivot-plugin-distribution-to-rubygems.md) | Plug-in 配布を rubygems に pivot、npm は `lilac-full` の CDN 配布のみに集約 | `runtime/mruby-lilac-*/lilac-*.gemspec` + `cli/lib/lilac/cli/package_discovery.rb` + Builder 統合 | 着手 (2026-05-23)、ADR-0026 で用語 rename |
| [0026](./0026-rename-plugin-to-package.md) | 「plug-in」用語を「package」に rename | gemspec / CLI / docs / tests / examples の機械的 rename | 完了 (2026-05-23) |
| [0027](./0027-class-first-handler-api.md) | Package Handler を class-first API として整備 (class-first principle) | `runtime/mruby-lilac-directives/mrblib/` + `cli/lib/lilac/cli/` + `docs/lilac-package-spec.md` | 完了 (2026-05-24)、Phase C/F は trigger 待ちで保留 |

## このドキュメントの位置付け

- **対象**: Lilac 開発者(framework 自体の開発)、Lilac で実装する利用者
  (Lilac の "なぜそう書くか" を知りたい)、設計レビュアー
- **更新頻度**: **月単位で累積**。新判断が出るたびに新 ADR を追加
- **`lilac-design.md` との関係**: design.md は **設計原則 (why の中核)**、
  ADR は **個別判断の log (how / when / what)**。design.md の原則は
  季節〜年単位の refinement、ADR は継続的に追加される
- **spec doc との関係**: spec は "現状の取説"、ADR は "決定の経緯と
  rationale"。spec を読んで疑問になった "なぜこうなっているか" が ADR で
  追える
- **過去判断の扱い**: 覆された判断の ADR ファイルは残し、タイトル冒頭に
  `(superseded by ADR-NN)` を付ける(歴史が adr/ 配下で追える)
- **`lilac-proposals.md` との関係**: proposals.md は **未確定の提案** を
  扱う。本 doc / ADR は確定判断のみ。提案が確定したら新 ADR として追加
  + 本 index に行追加、proposals.md からは削除する(昇格 operation の
  詳細は proposals.md 冒頭参照)
