# 26. 「plug-in」から「package」への用語 rename

決定日: 2026-05-23

## 26.1 判断

§24/§25 で「plug-in」と呼んでいた distribution unit を **「package」** に
rename する。rename 対象は **用語のみ**、機構そのもの (register_directive /
scan_extensions / mrblib auto-discovery) は不変。

- gem 名: `lilac-plugin-{extras,router,async}` → `lilac-{extras,router,async}`
- gemspec metadata: `"lilac_plugin" => "true"` → `"lilac_package" => "true"`
- CLI subcommand: `lilac plugin-build` → `lilac package-build`
- CLI クラス: `PluginDiscovery` / `PluginBuild` → `PackageDiscovery` / `PackageBuild`
- Config: `c.plugins = [...]` → `c.packages = [...]`
- Builder 内部: `copy_plugins!` → `stage_packages!`、`@plugin_dist_urls` →
  `@package_dist_urls`、manifest filename `lilac.plugins.json` →
  `lilac.packages.json`
- docs: `lilac-plugin-spec.md` → `lilac-package-spec.md`
- examples: `plugin-extras` → `package-extras`

## 26.2 背景

「plug-in」という呼称が **二系統で曖昧** だった:

1. **CRuby gem 期待との衝突**: `lilac-plugin-router` を `gem unpack` すると
   `lib/` が空で `mrblib/` だけある状態。CRuby gem のメンタルモデルを
   持ってきた user は「壊れてる?」「mrblib って何?」と困惑する
2. **directive plug-in と class plug-in の用語不整合**: extras は本物の
   「Lilac 拡張」だが router/async は単に Ruby class を提供するだけ。
   「Lilac に plug-in する」というメンタルモデルが router/async には
   合っていなかった

他フレームワーク命名を見渡した結果 (詳細は議論経緯):

- Vue: plug-in は厳密に `app.use()` する hook 持ちのもの限定
- Astro: integration
- VSCode / Browsers: extension
- Hugo: module
- Rails / Phoenix: 単に gem / package (特別な名前なし)

Lilac は **Ruby framework + wasm runtime** という構造上、どのカテゴリにも
完全に当てはまらない。検討した候補:

- `gem` — CRuby 期待を裏切るので不可 (本決定の trigger)
- `extension` — directive 系には合うが router/async には不正確
- `package` — 中立、distribution unit という意味だけを表す。多様な
  ecosystem (npm / pip / cargo) で確立。directive 系も class 系もカバー

## 26.3 rationale

- **中立性**: 「package」は中身を限定しない。directive を register する
  ものも、Ruby class を提供するだけのものも、同じ「Lilac package」と
  呼べる
- **CRuby gem との区別**: 「Lilac package」と呼ぶことで、これらが
  rubygems で配布されるが内部構造は CRuby gem と違う (mrblib) ことが
  暗黙に signal される
- **将来の拡張余地**: package は概念として「mrblib + assets + style + ...」
  と膨らんでも自然。extension だと「何を extend?」という質問が増える

## 26.4 トレードオフ

- **大量の rename 差分**: gemspec / CLI コード / docs / tests / examples
  全体に渡る。約 250〜300 行の機械的更新。pre-release の今だからできる
  作業。release 後だと breaking change になる
- **CLI subcommand 名の breaking change**: `lilac plugin-build` →
  `lilac package-build`。pre-1.0 なので許容範囲だが、scripts に書いた
  user は影響を受ける
- **history を残すため §23/§24/§25 内の "plug-in" 用語は維持**:
  decisions log は「当時の判断」を残すのが原則。これらは過去形として
  読めるよう、本 §26 から相互参照する

## 26.5 実装

機械的な rename。テストと example で動作検証する。

- 3 gemspec: file rename + spec.name + metadata key 更新
- CLI コード: 各 file rename + class rename + 内部参照更新
- Templates / scaffold: manifest filename + 例示更新
- Tests: file rename + 参照更新
- parity-runner: SCENARIOS の field 名更新
- examples: dir rename + Gemfile + README 更新
- docs: lilac-plugin-spec.md → lilac-package-spec.md (大幅 rewrite)、
  docs/README.md の index 更新、proposals.md の hot-reload 節も "package"
  用語に更新

## 26.6 後続作業

特になし。本 §26 は用語の整理であり、機能変更を伴わない。§25 の後続作業
(wasmtime-rb release 待ち / lilac-wasm-bin release pipeline / hot-reload
proposal の昇格判断 / 第三者 package template) は本決定の影響を受けず
そのまま継続。

## 26.7 ステータス

完了 (2026-05-23)。3 gemspec rename + CLI コード rename + tests + docs +
parity-runner + examples の機械的書き換えをまとめて commit 済み (commit log
参照)。残った "plug-in" 用語は §23 / §24 / §25 の history section のみで、
これらは「過去の判断」として意図的に保持。
