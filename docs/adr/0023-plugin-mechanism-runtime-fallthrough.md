# 23. Plug-in 機構: runtime canonical の延長としての runtime fallthrough

決定日: 2026-05-23

## 23.1 判断

「**配布時 modular 化**」を目的とする plug-in 機構を、§1 (runtime
canonical) の原則に厳密に従って実装する。Lilac 公式が機能を追加する際に
**runtime mrblib 1 ファイル**だけで完結し、CLI には手を入れない。

- **`Lilac::Directives::Scanner.register_directive(pattern:, kind:, phase:) { block }`**
  を plug-in 用 API として正式採用 (block 形式)
- Plug-in 作者は **mrblib に 1 ファイル書く**だけで directive を追加可能
- **CLI codegen 出力の `bind_template_hook` 末尾に
  `Scanner#scan_extensions(root.to_js, item:, except:)` を常に emit**
  する。Mount 時に runtime Scanner が DOM を走査し、CLI が知らない
  data-* directive を dispatch
- **`except:` には CLI が hand-tuned emit した kind を渡す**
  (現状: `[:form, :field, :button]` — form gem の hand-tuned emit と
  重複しないため)。Codegen が `EMITTERS.keys` から導出
- **`scan_extensions` は extension directive のみ dispatch**。Built-in
  directive (data-text 等) は extract_directives で skip
  (codegen が precompile 済み)。tag_hooks / collect_hooks も skip
  (これらは `lilac-full` の full scan path 専用、`lilac-compiled` では
  対応する CLI hand-tuned emit がカバーする)
- **Plug-in 作者が CLI を触るのは「extension を hand-tune して最適化したい
  場合のみ」** (例: form_extension.rb)。これは built-in directive の
  `emit_text` と同じ位置付けで、optional な optimization

## 23.2 背景

Step 2 (form 分離 + 拡張点 API 導入) で plug-in 機構ができたが、
Phase 1-5 でさらに「named API + AST scanning + naming convention」を
重ね、~500 行のインフラを構築。検証の結果、これらは §1 の原則
(runtime canonical) と緊張関係にあった:

- `register_named_directive` + AST scanning は、CLI が runtime を
  "読み取って" emitter を派生させる構造。CLI が runtime に依存する
  方向は、本来の "CLI は optional optimization" と逆向き
- 配布 modular 化 (Lilac 公式が機能を独立 gem として配る) という
  実際の目的に対しては overkill

User が明示した前提:
- 配布時に core + 個別機能 gem の選択が可能
- 公式が機能追加するたびに CLI を触るのは避けたい
- Runtime が canonical (§1) を厳密に守る

これを満たすには **runtime fallthrough** が筋。CLI は built-in だけを
hand-tune し、extension directive は runtime Scanner が mount 時に
拾う。

## 23.3 rationale

- **§1 (runtime canonical) を plug-in 領域にもそのまま適用**。
  CLI は built-in 用の precompile に専念
- **Plug-in 作者は mrblib 1 ファイル** で済む (CLI 不在で動く)
- **`lilac-compiled` でも plug-in 動作**: `mruby-lilac-directives` gem
  が compiled bundle に含まれているので Scanner#scan_extensions が動く
- **複雑度の劇的削減**: ~500 行のインフラ (PluginScanner、register_named_directive、
  Validation モジュール、handler / hook_X 規約、NAME_PATTERN、RESERVED_NAMES、
  Component#scanner accessor) を全部撤回
- **§17 のスコープを core grammar に限定** (§17 の本来の意図に戻る)

## 23.4 トレードオフ

- **Mount 時の追加コスト**: extension directive を持つ component で
  DOM walk 1 回追加。component あたり ~数十 μs、許容範囲
- **Build-time error が出ない**: Plug-in directive の値 typo は
  mount 時 `Lilac.logger.error`。§22 (form lint 撤回) と同じ方針
- **Block dispatch の stack trace**: Anonymous proc としてしか追えない
  (named method より追いにくい)。実害は logger.error の context で緩和
- **Phase :pre が built-in と協調しない**: scan_extensions は
  bind_template_hook の末尾で走るので、built-in より後。Phase :pre が
  必要な plug-in (form のような) は **CLI hand-tune (form_extension.rb)
  を併設**することで built-in と協調する。第三者 plug-in が同様の
  協調を必要としたら、同じく CLI hand-tune を書く
- **tag_hook / collect_hook は compiled では実行されない**: これらは
  `lilac-full` の full scan path 専用。Form の collect_hook
  (`validate_form_element` 等) は compiled では発火しない (dev-time の
  validation として `lilac-full` でのみ実行されればよい)
- **Extras gem のような plug-in は `lilac-compiled.rb` 直接 dep が必要**:
  Build config に `conf.gem` で明示。これは「配布時 modular 化」目的と
  整合 (ユーザが選んで gem を include する)

## 23.5 実装

- **Runtime**:
  - `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb`:
    - `register_directive(pattern:, kind:, captures_name:, phase:) { block }` 形式 (Step 2 と同等)
    - `scan_extensions(node_js, item:, except:)` メソッド追加
    - `dispatch_extensions_only` ヘルパ (tag_hooks をスキップする dispatch_record の variant)
    - `build_record` / `collect_subtree` / `extract_directives` に
      `extensions_only:` / `except:` パラメータを追加
  - `runtime/mruby-lilac-directives/mrbgem.rake` のデフォルト dep を path
    付きに更新 (lilac-compiled の transitive dep 解決のため、§23.6 参照)
- **Runtime (form / extras)**:
  - `runtime/mruby-lilac-form/mrblib/lilac_form_wiring.rb`:
    `register_directive` (block) で `:form` / `:field` / `:button` を登録、
    `register_collect_hook` / `register_tag_hook` も block で
  - `runtime/mruby-lilac-extras/mrblib/lilac_extras_*.rb`:
    `register_directive` (block) で `:tooltip` / `:autofocus` を登録
- **CLI**:
  - `cli/lib/lilac/cli/codegen.rb`:
    - `build_scope_body` の末尾に `scan_extensions_trailer` 呼び出し
    - `scan_extensions_trailer` は `EMITTERS.keys` を `except:` に渡す
      `scan_extensions` 呼び出し 1 行を emit
  - `cli/lib/lilac/cli/form_extension.rb` は **そのまま残す**
    (form 用 hand-tuned emit。built-in 級 optimization)
  - `cli/lib/lilac/cli/plugin_scanner.rb` 削除
  - `cli/lib/lilac/cli/builder.rb` の plugin scan 関連削除
- **Build config**:
  - `build_config/lilac-compiled.rb`: `mruby-lilac-directives` +
    `mruby-lilac-extras` を direct dep として明示 (もとは form gem の
    transitive dep だったが、extras 追加時に mruby の dep resolution
    で `mruby-regexp-compat` が解決できなかったため明示が安全)

## 23.6 §17 への影響 (本 §23 と整合)

§17 の SSOT 構造に補足を追加:

- **Plug-in directive の dispatch logic は mrblib 単一 SSOT**
  (CLI は知らない、知る必要もない)
- **§17 の diff-0 ペアルールの対象は core grammar に限定**
  (`Value` / `Grammar` / `ClassParser` / `compat_rules`)。
  Plug-in は対象外
- `Scanner` に新メソッド `scan_extensions` を追加 (runtime fallthrough 用)

## 23.7 後続作業 (本決定スコープ外)

- `data-on-X` のような **captures_name 系 directive** は plug-in 用
  API では現状サポート (block 形式の `register_directive` で `captures_name: true`)
  だが、第三者 plug-in が実際に使う想定なし。需要が出てきたら検討
- Plug-in 作者向けドキュメント (`docs/lilac-directive-plugin-spec.md`
  等) 整備
- `lilac dev` の **hot-reload** で mrblib 変更を即反映する仕組み
- `lilac-compiled` build で plug-in gem 不在を **build error として検出**
  する仕組み (現状は runtime で no-op、症状の追跡が困難なケースあり)
- Form の **collect_hook 由来 dev-time validation** を
  `lilac-compiled` でも動かす場合の方針 (現状は `lilac-full` 専用)

## 23.8 ステータス

完了 (2026-05-23):

- Runtime: `register_directive` + `scan_extensions` 実装、72 spec files pass
- CLI: codegen 末尾に scan_extensions trailer emit、PluginScanner 撤回、
  470 CLI test runs pass
- Form / Extras: block 形式の `register_directive` に書き戻し、動作確認
- `lilac-compiled` build: 2.9M bundle、extras 動作確認
- 削減: ~500 行 (Phase 1〜§23 当初版で構築したインフラを撤回)

## 23.9 経緯 (sunk cost の記録)

Step 2 (form 分離) 完了後、ergonomics 改善 (mrblib only / 1 ファイル
plug-in) を目指して以下を順次構築・撤回した:

- §23 第 1 版: `register_named_directive` + `handler:` + `hook_X` 命名 +
  4 軸 metadata schema (`value:` / `allowed_tags:` / `conflicts_with:` /
  `iteration:`) + AST scanning + Validation diff-0 ペア + Component#scanner
- §23 第 2 版: metadata schema を `value:` のみに簡素化
- §23 第 3 版: `value:` も撤回、`(name, handler:)` 最小化
- §23 第 4 版 (本決定): named API 自体を撤回、`register_directive` (block)
  + runtime fallthrough に統一

User フィードバックで「配布 modular 化 + CLI 不要 + runtime canonical 厳密
適用」が真の目的と判明し、AST scanning と命名規約は overkill だった
ことが明確化された経緯。
