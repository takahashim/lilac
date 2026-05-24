# 17. directive binding は codegen が canonical / scanner gem は grammar reference

決定日: 2026-05-19

## 問題

`:full` target と `:compiled` target で binding 経路の責務が曖昧だった。

- 元の設計(decisions §1)では runtime canonical を謳い、`mruby-lilac-directives`
  gem の `Scanner` が DOM walk で directive を解釈する想定だった
- ところが CLI codegen は `data-each` の row body を `<template
  data-template="lil-each-...">` に **抽出** する。同じ HTML を `:full` で
  runtime scanner に食わせると、空の `<li data-each>` を見て row template を
  recover できず `tagName of null` で落ちる(parity 検証で発覚)
- builder.rb は `:full` だけ `[user_script, generated]` の順で emit して
  いたが、`Lilac.start` の時点で `Lilac::Bindings::<Class>` モジュールが
  まだ未定義のため、結局 scanner fallback に落ちて上記の bug を踏む
- かつ `:full` でも codegen 生成コードを並走させていて、scanner と codegen
  の binding が二重発火しうる構造になっていた

scanner と codegen は同じ grammar を **2 言語実装** している状態で、
`it.path` 削除のような変更が両側に対称に出る。`Lilac::Directives::Value`
と `Lilac::CLI::DirectiveValue` が並存し、片方を直して片方を忘れる事故が
起きやすい(実例: §16 の作業中に CLI 側だけ regex anchor を変更して runtime
側と挙動が divergent になりかけた)。

## 決定

**binding 経路の canonical を codegen に統一**。scanner gem は「directive
grammar の reference 実装」「`codegen :off` モードの escape hatch」として
位置付ける。

具体的な変更は 2 軸:

### A. binding canonical = codegen

- `:full` / `:compiled` 両 target で **codegen 生成コードを user_script
  より前** に置く(`[generated, user_script]`)
- 両 target とも `emit_include: false`(codegen は `Lilac::Bindings::<Class>`
  モジュールを定義するだけで、明示的な `<Class>.include` は emit しない)
- `Lilac::Component#bind_template_hook` が **on-demand で**
  `lookup_codegen_bindings` → `self.class.include(bindings_mod)` →
  re-dispatch する。`Lilac.start` 時点で bindings モジュールが在ること
  だけが必要で、explicit include の有無は問わない
- scanner gem は **`bind_template_hook` 既存実装が無い場合の fallback
  経路**(= `codegen :off` の escape hatch)としてのみ残る

### B. directive grammar の SSOT 構造 (`Lilac::Directives::*`)

CLI 側の文法レイヤを `Lilac::CLI::*` から **`Lilac::Directives::*`** に
rename し、runtime 側と完全に同名にする。`diff(1)` で片方の編集忘れを
即発見できる構造に再編。

```
cli/lib/lilac/directives/                runtime/mruby-lilac-directives/mrblib/
  value.rb            ──── diff 0 ────  lilac_directives_value.rb
  grammar.rb          ──── diff 0 ────  lilac_directives_grammar.rb
  class_parser.rb     ──── diff 0 ────  lilac_directives_class_parser.rb
  collision_rules.rb  ──── diff 0 ────  lilac_directives_collision_rules.rb
  lints.rb            ──── role-別 ──   lilac_directives_lints.rb
                                         (build-time raise vs runtime warn+skip)
  value_codegen.rb    ──── CLI のみ ──  (Value::Ivar / BareIdent を re-open し emit helper を追加)
  grammar_extra.rb    ──── CLI のみ ──  (class_name? / ref_ident? + INNER 定数)
```

> **註 (2026-05-24)**: 当初 `compat_rules.rb` / `compat.rb` 命名、module 名
> `Lilac::Directives::Compat` だったが、[ADR-27](./0027-class-first-handler-api.md)
> Phase L で `collision_rules.rb` / `lints.rb` / `Lilac::Directives::Lints` に
> rename。理由は「`Compat` が CLI/runtime 互換性に誤読されがちで、実体は
> directive 衝突 lint」だったため。本 §17 の SSOT 構造 + diff-0 pair 運用は
> そのまま維持されており、命名のみの変更。

運用ルール:

1. **diff-0 ペア**(`value.rb` / `grammar.rb` / `class_parser.rb` /
   `compat_rules.rb`)は本体を編集する PR で **両方を同時に同じ内容で
   更新する**。片側だけの修正は spec 違反とみなす
2. **role-別ペア**(`compat.rb`)は同じ `COLLISION_PAIRS`(= `compat_rules.rb`
   の SSOT)を consume するが、上位ロジックは別実装で構わない。`COLLISION_PAIRS`
   に行を足したら両 logic がそれを拾うことを test で確認
3. **CLI 専用 extra**(`value_codegen.rb` / `grammar_extra.rb`)は
   build-time にしか意味がないコード(emit helper / 静的検証 predicate)
   を re-open で追加する。runtime に伝播させてはいけない
4. `require_relative` は **個別の `directives/*.rb` 内に置かない**(runtime
   側は mrbgem の concat ロードなので require が無く、CLI と diff を取る
   際のノイズになる)。`cli/lib/lilac/directives.rb`(loader)に集約し、
   各 caller(`codegen.rb` / `cross_ref_linter.rb`)が
   `require_relative "../directives"` で束ねを引き込む

### scanner gem の役割整理

`mruby-lilac-directives` gem は廃止しない。役割を再定義:

- **directive grammar の参照実装**: `Value` / `Grammar` / `ClassParser` /
  `Compat` の挙動定義として canonical。spec doc から疑問が出たときに
  「コードがどう書かれているか」を見に行く先
- **`codegen :off` モードの escape hatch**: CLI を介さず `<script
  type="text/ruby">` 直書きで Lilac を試したいケース(prototype /
  教育用デモ / オフライン HTML)で、runtime scanner だけで動かす経路を
  維持
- **bundle 影響**: scanner gem を `:full` から外せば数十 KB 削れる
  余地があるが、上記 2 用途のために残す判断。将来 bundle 圧縮の
  要件が出てきたら再評価

decisions §1 の「runtime canonical」記述は本 §17 で「**binding 経路は
codegen が canonical / grammar 解釈の参照実装は scanner**」に読み替える。

## 影響

- `:full` target で data-each を含む component が parity-runner で
  正しく動く(`tagName of null` バグ解消)
- 「片方だけ修正した PR」が `diff(1)` で機械的に発見できる
- `Lilac::CLI::DirectiveValue` などの旧名は完全消滅(CLI 内部参照は
  すべて `Lilac::Directives::*` に置換)
- 残る duplicate は本質的に同じ実装で、変更コストは 2x のままだが、
  片方の漏れは即検出される(従来は気付かないままズレるリスクがあった)

## 反映先 spec

- 本 § 自体が SSOT。`lilac-directive-spec.md` への明示的反映は不要
  (grammar 仕様自体は不変、実装構造の話)
- 命名・ファイル構造は実装ファイル(`cli/lib/lilac/directives/` 配下、
  `runtime/mruby-lilac-directives/mrblib/` 配下)が SSOT

## 実装

- `cli/lib/lilac/cli/builder.rb`: concat order を `[generated,
  user_script]` に統一、`emit_include: false`
- `runtime/mruby-lilac/mrblib/lilac_component.rb`:
  `lookup_codegen_bindings` + 再 dispatch で on-demand include
- `runtime/mruby-lilac/mrblib/lilac_ref.rb`: `Refs#collect` /
  `TemplateRefs#[]` が root 要素の `data-ref` も拾うよう拡張
  (codegen 一本化に伴い template root に data-ref が乗るケース対応)
- `cli/lib/lilac/directives/*.rb` 新設、`Lilac::CLI::*` から rename
- `cli/lib/lilac/directives.rb` (loader)
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_collision_rules.rb`
  新設(`COLLISION_PAIRS` SSOT。当初は `lilac_directives_compat_rules.rb` の名だったが、
  ADR-27 Phase L で rename)
- `test/parity-runner.mjs` + `test/parity-fixtures/`: `:full` と
  `:compiled` で DOM が一致することを継続的に検証

---
