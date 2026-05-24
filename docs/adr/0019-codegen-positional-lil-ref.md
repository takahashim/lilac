# 19. Codegen positional `lilN`(`data-ref` 注入の廃止)

決定日: 2026-05-20

## 問題

§17 で codegen canonical を確立した直後、§18 で `lilac build --target
compiled` を「ノービルドで動く dist」まで仕上げようとしたところ、
page-inline `<X data-component="...">` をサポートする際に **`data-ref="lilN"`
の build-time 注入** が破綻した:

- `.lil` flow では template body は `.lil` 内で孤立した chunk → TemplateAST
  が Nokogiri で mutate(`data-ref` 付与)→ `<lilac-component>` 展開時に
  inline、で完結。page の outer HTML は不変
- page-inline flow では data-component subtree が page HTML 内に直接ある
  → refs を付与するには page HTML 全体を mutate して書き戻す必要があり、
  Nokogiri::HTML5.parse/fragment の round-trip が page の `<html>`/`<body>`/
  whitespace を正規化してしまい、ユーザの書いた page が build 後に
  byte-identical でなくなる

2026-05-20 の 7guis gallery で `Missing ref: lil0 in CounterTask` を踏み、
subtree mutation + string splice の力技も Nokogiri round-trip 経由で page
の outer 構造(`</body>` 消失等)を壊す経路に突入して、design レベルで
筋が悪いと判明した。

## 決定

**bind ID は build 時に発行しない — `refs.lilN` を runtime で positional
に解決する**。codegen の出力テキストは不変、HTML mutation だけ廃止する。

具体的には:

### A. TemplateAST は HTML を mutate しない

- `assign_or_reuse_ref` の `elem["data-ref"] = candidate` を削除
- 同一 element の synthetic ref ID は **per-scope index**(`current_ref_scope.size`)
  に切り替え。ref_id "lil0" は「**この scope での 0 番目の directive-bearing
  element**」を意味する
- `current_ref_scope` には user-declared `data-ref` も登録される(scope 内
  ユニーク検査用)ので size は名前付き + 合成の合計を反映 — runtime も
  同じ規約で count する
- user-declared `data-ref="lilN"` は **build error**(`lilN` namespace は
  codegen 予約)

### B. Runtime Refs / TemplateRefs は positional 解決

- 構築時に component 部分木を DFS preorder で walk
- `data-ref` 付き element → `@cache[name]` に登録(従来通り)
- directive-bearing element(`Lilac::Directives::Grammar::DIRECTIVE_ATTR`
  に match する `data-*` 属性を持つ)→ `@positional` 配列に追加
- `refs[X]` lookup: `@cache[X]` を優先、ヒットしなければ X が `lilN`
  形式なら `@positional[N]` にフォールバック、いずれも無ければ raise
- TemplateRefs(iteration row clone)は別 instance として同じ walk を
  row subtree に対して行う — `t.refs.lil0` は row clone の 0 番目を返す

### C. compat check は (scope_id, ref_id) でグルーピング

build-time の `Lilac::Directives::Compat.check!` が directives を ref_id
で group_by していた箇所を `[scope_id, ref_id]` のタプルに変更。同じ
"lil0" が top-level scope と data-each iteration scope の両方に現れても
別グループとして扱う(両者は別 element)。

### D. DIRECTIVE_ATTR の SSOT 拡張

`Lilac::Directives::Grammar::DIRECTIVE_ATTR` 正規表現を build-time
(`cli/lib/lilac/directives/grammar.rb`)と runtime
(`runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb`)で
diff-0 ペアとして追加。

`lilac-compiled` 変種は `mruby-lilac-directives` gem を含まないので、
`mruby-lilac` 側(`Refs::DIRECTIVE_ATTR_RE`)に **同じ regex を duplicate**
する。コメントで 3 ファイル間のペアリングを明示。

### E. `<X data-field="...">` 内部 input への合成 `data-ref` だけ例外的に残す

`find_or_allocate_form_control_ref` は wrapper 要素 + 中の input という
組み合わせ専用の経路。input 本体は **directive-bearing ではない**(`data-*`
attribute を持たない)ので、runtime の positional walk では拾えない。
ここでは入力要素に `data-ref="lilN"` を mutation して名前付きとして登録
する(`@cache["lilN"]` で引ける)。これは局所的・既知の例外。

## 影響

- **page HTML が build 時 byte-for-byte 不変**: コメント・whitespace・
  attribute 順、すべて保存。「Lilac は HTML を foreign code に変質
  させない」原則と整合
- **page-inline data-component の codegen サポート**: §18 の
  `scan_page_components` で書いた Nokogiri 書き戻しロジックは廃止。
  代わりに `synthesize_page_inline_components` が page-inline subtree を
  in-memory `SFC::Component` として組み立て、`<lilac-component>` placeholder
  に置換するだけの軽量変換になる
- **dist HTML 軽量化**: 合成 `data-ref="lilN"` ノイズが消える
- **テスト追従**: `test_template_ast.rb` の synthetic ref-attribute assertion
  を反転(`refute_match(/data-ref="lil0"/`)。collision-skip テストは
  `lilN` namespace 予約テストに置き換え。runtime spec の "invalid data-ref
  name raises" は「missing template ref」に正規化
- **parity test**: `:full` / `:compiled` で DOM 一致を継続検証(変更後
  も全シナリオ pass)

## 反映先 spec

- 本 § が SSOT
- `cli/lib/lilac/directives/grammar.rb` と
  `runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb` に
  `DIRECTIVE_ATTR` 正規表現を追加(diff-0 ペア)
- `runtime/mruby-lilac/mrblib/lilac_ref.rb` に `Refs::DIRECTIVE_ATTR_RE`
  を duplicate(scanner gem を含まない `lilac-compiled` でも使えるよう)
- `decisions §17` の "codegen canonical" 方針は不変(本決定は内部表現
  の変更で、canonical の主体は引き続き codegen)
- `decisions §18` の `scan_page_components` 周り(Nokogiri 書き戻し力技)は
  本決定で不要になり、`synthesize_page_inline_components` に置換済み

## 実装

- `cli/lib/lilac/cli/template_ast.rb`:
  - `assign_or_reuse_ref` を per-scope counter + mutation 廃止に書き換え
  - `find_or_allocate_form_control_ref` を per-scope counter に揃え、
    `own_ref:` 引数経由で同一 input のケースを処理
  - `register_ref!` に `lilN` namespace 予約チェック追加
  - 直前 `find_or_allocate` が登録した synthetic と walker の elsif の
    重複登録を回避するガード
  - `@ref_counter` 廃止
- `cli/lib/lilac/cli/builder.rb`:
  - `synthesize_page_inline_components` 新設(page-inline data-component を
    in-memory `SFC::Component` 化 + `<lilac-component>` placeholder swap)
  - 旧 `scan_page_components` / `page_components` 引数 / Nokogiri 書き戻し
    ロジックを撤去
  - `build_injection` の signature を `page_inline_scripts:` のみに簡素化
- `cli/lib/lilac/directives/grammar.rb` + `runtime/mruby-lilac-directives/mrblib/lilac_directives_grammar.rb`:
  `DIRECTIVE_ATTR` regex + `directive_attribute?` 述語を追加(diff-0 ペア)
- `cli/lib/lilac/directives/compat.rb`: group_by を `[scope_id, ref_id]`
  タプルに変更
- `runtime/mruby-lilac/mrblib/lilac_ref.rb`:
  - `Refs` に `LILN_RE` / `DIRECTIVE_ATTR_RE` / `@positional` / `directive_bearing?`
    を追加。lookup に `lilN` positional fallback を生やす
  - `TemplateRefs` を querySelector ベースから positional walk ベースに
    書き換え(構築時に row clone を walk、cache + positional 両建て)
- tests 更新済み(`cli/test/test_template_ast.rb`, `cli/test/test_template_ast_form.rb`,
  `runtime/mruby-lilac/wasm_spec/test_template.rb`)。CLI test 382 runs all green、
  runtime wasm_spec 617 tests all green、parity-runner all scenarios pass

---
