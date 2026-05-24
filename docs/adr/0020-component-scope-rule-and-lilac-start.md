# 20. Component scope rule の確定 と `Lilac.start` 自動化

決定日: 2026-05-20

## 問題

§18(compiled target 統合)+ §19(positional `lilN`)の着地で Lilac の
component 定義場所が **3 つ** 並ぶ形に揃った:

1. `components/*.lil` — SFC 形式の単一ファイル component
2. page-inline `<X data-component="name">` — page HTML 中に直接書かれた
   component 要素(class 定義は同 page の `<script type="text/ruby">` 内)
3. page-inline `<script type="text/ruby">` — page HTML 中のロジック塊

しかしこの 3 階層は **scope rule が明文化されておらず**、silent failure を
許す状態だった:

- `.lil` の `Counter` と page-inline `<div data-component="counter">` が衝突
  しても `synthesize_page_inline_components` の `synthesized[name] = ...` が
  **無条件上書き** → user は `.lil` 側が使われていると誤認する
- 同 page 内で同名 page-inline component が複数あっても build error には
  ならず、最後の宣言が勝つ
- 別 page で同名 page-inline component を **別形** に書いても警告がなく、
  共有部品のつもりが page ごとに違う挙動になっていることに気付けない
- page-inline `<script type="text/ruby">` 内で `.lil` 由来 class と同名の
  class を定義しても Ruby 的には reopen として通り、build は成功するが
  挙動が壊れる

並行して **`Lilac.start` の責務分布が target 間で非対称** だった:

- target=full: user が `<script type="text/ruby">` に `Lilac.start` を書く
- target=compiled: builder が bundle 末尾に `Lilac.start` を自動 append

§18 が「同じ markup で両 target を切替可能」を目標にして着地した一方、
`Lilac.start` だけ user 責務が target に依存していて、これまで潰してきた
非対称性の最後の残滓になっていた。

Ruby の通常の常識(実行開始は明示)からは「`Lilac.start` を書かないで
済ませる」は素直ではない。これを framework 設計として正当化する位置づけが
必要だった。

## 決定

3 階層の scope rule を明文化 + build-time guard で衝突を潰す(A)、
`Lilac.start` を framework 内部の boot 呼び出しとして user 空間から外す(B)。

### A. component scope rules (R1〜R4)

| 定義場所 | 名前空間 | 可視範囲 | 用途 |
|---|---|---|---|
| `components/*.lil` | **project-global** | どの page からも参照可 | 複数 page で共有する部品 |
| page-inline `<X data-component>` | **page-local** | その page 内 (nested 含む) のみ | その page 専用 compose 単位 |
| page-inline `<script type="text/ruby">` | **page-local 実行スコープ** | その page の `.mrb` 内 / `evalScript` 範囲 | その page の class 本体 / setup |

build-time guard(`cli/lib/lilac/cli/builder.rb`):

- **R1**: `.lil` と page-inline で **同名は build error**(silent override 禁止)。
  実装は `synthesize_page_inline_components` 冒頭で `lil_origin = components.keys.to_set`
  を捕捉、page-inline ループで `if lil_origin.include?(name)` なら raise
- **R2**: 同 page 内で同名 page-inline component の重複は **build error**。
  `seen_in_page = {}` を抱えて `if seen_in_page.key?(name)` なら raise
- **R3**: cross-page で同名 page-inline component が別形のとき **warning**。
  build 全体で `@page_inline_signatures = { name => [[content_hash, page_path], ...] }`
  を蓄積、終端 `warn_cross_page_signature_drift!` で同名異 hash を stderr 警告。
  シグネチャは whitespace 正規化後の SHA1 で比較
- **R4**: page-inline `<script type="text/ruby">` で定義する class 名が
  `.lil`-derived class 名と衝突したら **build error**。`ScriptAnalyzer.extract_top_level_class_names`
  で page-inline script 内の top-level class 名を Prism で抽出、`.lil` の
  `ComponentName.new(name).ruby_class` と突き合わせ。`check_class_name_collisions!`

R3 を error ではなく warning にしたのは、(a) 別 page で同名・同形を書く
ケース(分離 dist でも同じ button 部品など)を許容したい、(b) build を
止めるほどの実害はない(別 `.mrb` に閉じるので runtime 衝突は起きない)、
の 2 点。drift があった時に気付ければよく、強制ではない。

### B. `Lilac.start` を framework 内部の boot 呼び出しに

#### B.1 設計の位置づけ — user 空間は宣言、framework が dispatch

user code を **procedural script ではなく declaration** として位置づける:

- user の Ruby = `class Counter < Lilac::Component` という **宣言**
- 「呼ぶ側」 = DOM 上の `<div data-component="counter">` という **dispatch
  指示**(DOM が dispatch table)
- dispatcher = framework 自身

Rails の `class PostsController < ApplicationController` の隣に
`rails server` を書かないのと同じ理屈で、Lilac でも `class Counter` の隣に
`Lilac.start` を書かない。`Lilac.start` は **framework internal な boot
呼び出し**で、user 空間ではない。

Ruby の明示性原則(`class Foo; end` は何もしない)と矛盾しないのは、
user 空間 = 宣言の集合 / framework 空間 = dispatch という責務分離が
成立しているため。

#### B.2 `Lilac::Registry#start` の idempotency

builder が自動 append する `Lilac.start` と user が明示的に書いた
`Lilac.start` が共存しても二重 mount しないことを保証する。

実装は **`start` 自体に explicit guard を追加するのではなく、内部 op が
すべて idempotent なので外側 guard は不要**(下記 caveat 参照):

- `install_observer` — `return if @observer` で 1 回しか install しない
- `prune_disconnected_components` — 切断済み component を消すだけ、二度
  実行で害なし
- `mount_subtree` — 各 element の `data-component-id` 属性を見て mount 済み
  なら skip(`existing_attr.js_null?` チェック)

**Caveat (2026-05-20 追記)**: 初版実装では explicit `@started` guard
(`return if @started; @started = true` + `reset!` で false 復帰)を入れて
いたが、これは runtime wasm test の `body[:innerHTML] = "..."; Lilac.start`
パターン(DOM を入れ替えた後の再 mount)を妨害してしまい test スイートを
壊した。internal ops が既に idempotent なので、explicit guard は redundant
かつ有害だった。よって `@started` guard は撤去し、idempotency は internal
ops の性質に委ねる形に修正した。

#### B.3 builder が target を問わず boot を auto-append

- target=compiled: 既存の bundle 末尾 `+ ["Lilac.start"]` を維持
  (`vm.loadBytecode` 完了 = 全 user Ruby 評価完了 = boot 発火)
- target=full: `bundle_scripts` の else 枝に `any_user_ruby ? scripts + ["Lilac.start"] : scripts`
  を追加。bridge JS の `querySelectorAll('script[type="text/ruby"]').forEach(...)` の
  eval loop が最後の injected block で `Lilac.start` まで到達する形

#### B.4 boot タイミングの spec

framework boot は **bootstrap module の eval loop 直後** で発火する。
「全 user Ruby 評価済み」は実行時に検出するのではなく、bootstrap module
上のコード位置として保証される:

- target=compiled: `vm.loadBytecode(bundle)` の直後
- target=full: bridge が `<script type="text/ruby">` を `evalScript` し終えた直後

これは framework が eval loop を所有しているため決定論的に確定する。
ES module script の暗黙 defer により、bootstrap が走り始める時点で既に
DOM 全体が parse 済 → `data-component` 要素も `text/ruby` 要素も全部
存在 → 明示的な `DOMContentLoaded` listener は不要。

#### B.5 position 依存性の境界(invariant)

builder emit / scaffold が bootstrap を **常に `<script type="module">` で
emit する** ことが invariant の前提:

| script 種別 | 位置依存性 |
|---|---|
| `<script type="module">` bootstrap | 非依存(暗黙 defer) |
| classic `<script src>` bootstrap | 依存(`<head>` だと壊れる) |
| `<script type="text/ruby">` user code | 非依存(browser が実行しない) |
| `.lil` ファイル | N/A(CLI が build 時に消費、browser に届かない) |

target=full の eval order は document order で、user の前方参照
(`class B < A` を `class A` より先に書くなど)には注意が必要だが、これは
browser の defer とは無関係の「Ruby の通常の load order」の問題。

### C. 既存 example の `Lilac.start` 削除

`examples/7guis/public/boot.js` から明示的な `vm.eval("Lilac.start")` 行を
削除。boot.js は `querySelectorAll('script[type="text/ruby"]').forEach` の
eval loop だけを残し、loop の最後で builder が append した `Lilac.start` が
評価されて boot する形にした。

## 影響

- **scope の認知負荷**: 「どこに書いたら誰から見えるか」が表 1 つで説明
  できる状態。silent shadowing 事故が build error として検出される
- **target 切替の対称性**: user code は target を問わず同一(`Lilac.start`
  を書かない)。`lilac build --target full` と `--target compiled` を
  user code 無修正で切替可能(§18 と §1 の意図的な完成)
- **user code の宣言性**: class 定義 + DOM の data-* 属性だけで完結。
  procedural な entry point を含まない。Rails / Stimulus と同じ責務配分
- **既存 user code の互換**: idempotent (B.2) により `Lilac.start` を
  明示的に書いている既存 page もそのまま動く(builder の append が no-op に
  なる)。bridge JS から `vm.eval("Lilac.start")` を削除しても idempotent の
  おかげで safety net が残る
- **テスト**: builder spec に R1〜R4 collision case + auto-Lilac.start
  case を 8 件追加。total 390 runs all green
- **boot タイミングは仕様化された**: ES module deferral に依存することを
  明文化、bootstrap を classic script で書き換えると壊れることが明示的に
  guarantee の外と位置付けられる

## 反映先 spec

- 本 § が SSOT
- 実装は `cli/lib/lilac/cli/builder.rb`(R1〜R4 guard + auto boot inject)、
  `cli/lib/lilac/cli/script_analyzer.rb`(R4 用 `extract_top_level_class_names`)、
  `runtime/mruby-lilac/mrblib/lilac_registry.rb`(idempotent `start` + `reset!`)
- proposals.md からは該当節(「コンポーネント scope rule の確定と
  `Lilac.start` 自動化」)を削除
- [ADR-0001](./0001-runtime-canonical.md)(runtime canonical / CLI optional)
  — B の boot 統一は「target 切替が user code を変えない」原則の補完
- [ADR-0018](./0018-lilac-build-compiled-single-command.md) — 本決定は
  ADR-0018 が露呈させた scope と boot の非対称性を解消する後続整備

## 実装

- `cli/lib/lilac/cli/builder.rb`:
  - `synthesize_page_inline_components` に R1 (lil_origin)、R2 (seen_in_page)
    の guard を追加。R3 の signature 記録もこのループ内
  - `build_page` で `check_class_name_collisions!` を `build_injection` 直前に
    呼び出す(R4)
  - 新 method: `check_class_name_collisions!`, `signature_for`,
    `warn_cross_page_signature_drift!`, `build_scope_error_message`
  - `@page_inline_signatures` ivar を `build` で初期化、`warn_cross_page_signature_drift!`
    を pages.each ループ後に呼ぶ
  - `bundle_scripts` で `any_user_ruby` の有無を見て full mode でも
    `+ ["Lilac.start"]` を append
- `cli/lib/lilac/cli/script_analyzer.rb`:
  - `extract_top_level_class_names` / `collect_top_level_class_names` を新設
    (Prism の `ClassNode#constant_path` から名前抽出)。nested class は
    対象外(top-level scope のみ)
- `runtime/mruby-lilac/mrblib/lilac_registry.rb`:
  - 当初は `@started` ivar + explicit guard を入れたが、internal ops
    (`install_observer` / `mount_subtree` / `prune_disconnected_components`)
    が既に idempotent であること、explicit guard が test の DOM 入れ替え
    パターンを妨害することから撤去(B.2 Caveat 参照)。実装としては
    現状 `start` に追加 guard なし
- `examples/7guis/public/boot.js`:
  - explicit `vm.eval("Lilac.start")` を削除、boot は builder の自動 append に
    委譲。idempotent guard が safety net として効くので bridge から消しても
    user が書いた既存 page は壊れない
- tests:
  - `cli/test/test_builder.rb` に §B (auto Lilac.start) と §A (R1〜R4) の 8 件
  - CLI test 390 runs, 1085 assertions, all green

## 20.6 Refinement: `Lilac.start` の責務を boot helper layer に統一(2026-05-20)

§20.B の初版は **builder が `Lilac.start` を auto-inject する** 実装で
着地したが、§1(Runtime canonical / CLI optional)との整合性レビューで
**「user が `Lilac.start` を書かない」規約が CLI 利用時にしか成立しない**
drift が見つかった:

- CLI target=compiled / target=full: builder が `Lilac.start` を append
- runtime-only HTML(`@takahashim/mruby-wasm-js` を直接 import する Pattern B): user が手書きで `Lilac.start` を call する必要

§1 の "CLI は optional な最適化レイヤ" 原則からすると、boot の framework
責務は CLI の特権機能ではなく、**Lilac-specific boot helper layer** に
属させるべき。

### 再構成内容

`Lilac.start` の発火位置を builder から boot helper layer に移動:

- **target=compiled の `render_compiled_boot_module`**: 初版は
  `vm.loadBytecode(bytecode)` の直後で `vm.eval("Lilac.start")` を呼ぶ案
  だったが、**compiled 変種の wasm は `mruby-compiler` / `mruby-eval` を
  含まない** (build_config/lilac-compiled.rb 参照) ため、post-load の
  `vm.eval` で任意 Ruby ソースを評価できない。よって target=compiled では
  **builder が bundle bytecode 末尾に `Lilac.start` を append し、
  `loadBytecode` の top-level 実行で boot が走る** という形に揃える。
  inline boot module は `loadBytecode` だけを呼ぶ
- **target=full の Lilac-specific boot helper**(例: `examples/7guis/public/boot.js`):
  `document.querySelectorAll('script[type="text/ruby"]').forEach(eval)` の
  **直後** に `vm.eval("Lilac.start")` を呼ぶ。target=full は parser を持つので
  ここは runtime 側で発火
- **runtime-only path で `@takahashim/lilac-full` の `boot()` を使う場合**:
  将来 `boot()` 自体も eval 完了後に `Lilac.start` を呼ぶようにする(別 PR、
  本決定の対象外。idempotent guard があるので即時の修正は不要)
- **Pattern B(user が自前で createVM + vm.eval を組む runtime-only)**:
  user が `Lilac.start` を Ruby 側に書くか、自前 bridge wrapper の最後で
  `vm.eval("Lilac.start")` を呼ぶ。framework 側に責任は無い(自前 bridge を
  書く以上 boot 呼び出しも user 責務)

### 影響

- **user code の対称性**: `lilac build --target full` / `--target compiled` /
  CLI を使わず `boot()` helper を import する runtime path、いずれも user は
  `Lilac.start` を書かない
- **builder の責務縮小**: full mode で `any_user_ruby ? scripts + ["Lilac.start"] : scripts`
  の特例処理が消える。compiled mode の bundle 末尾 append は parser 制約から
  維持(下記 caveat)
- **bytecode と boot helper の責務分担**: target=full は boot helper layer
  (JS) が boot を所有。target=compiled は parser 制約で「bundle 末尾の
  `Lilac.start` を builder が pre-compile」が依然必要 — boot helper layer の
  "boot 担当者" 役は inline boot module の `loadBytecode` 呼び出しが果たす形
  (bytecode を実行する = boot を実行する)
- **§1 整合**: "CLI は optional な最適化レイヤ" 原則がより純粋に成立。
  CLI を介さない runtime-only path でも(適切な boot helper を使う限り)
  user code が同じ形を保つ

### 影響を受ける箇所

- `cli/lib/lilac/cli/builder.rb`:
  - full mode: `any_user_ruby ? scripts + ["Lilac.start"] : scripts` を
    `scripts` に戻す(boot は boot helper layer 側)
  - compiled mode: bundle 末尾の `+ ["Lilac.start"]` append は **維持**
    (parser 制約のため bytecode に embed する必要あり)
  - `render_compiled_boot_module` は `loadBytecode` だけを呼ぶ形に戻す
    (`vm.eval("Lilac.start")` は parser が無いため使えない)
- `examples/7guis/public/boot.js`:
  - eval loop 末尾に `vm.eval("Lilac.start");` を復活(§20.C の削除を
    取り消す形 — boot.js こそが boot helper layer の実体)
- `cli/test/test_builder.rb`:
  - `test_target_full_auto_appends_lilac_start` を `test_target_full_does_not_inject_lilac_start_into_script_block` にリネーム
    (アサーションを反転 — Lilac.start が **inject されない** ことを確認)
  - `test_target_compiled_bundle_includes_lilac_start` を
    `test_target_compiled_bundle_includes_lilac_start_in_bytecode` にリネーム
    (`.mrb` 内に Lilac / start sym が残ること + boot module が `vm.eval` を
    呼ばないことを確認 — parser 不在 caveat)
  - `test_target_full_no_lilac_start_when_page_has_no_ruby` を
    `test_target_full_pure_static_page_emits_no_script_block` にリネーム
    (Ruby 無しの場合は injection そのものが起きないことの確認)
- idempotent `Lilac::Registry#start`(§20.B.1)は据え置き — user が手書きで
  `Lilac.start` を書いた既存コードへの safety net として依然必要

CLI tests 390 runs, all green。examples/7guis の full / compiled 両 build も
確認済み:
- target=full の dist HTML に `Lilac.start` 無し、boot.js が eval loop 末尾で発火
- target=compiled の bundle bytecode に `Lilac.start` を builder が append、
  inline boot module は `loadBytecode` のみ呼んで boot が走る

**Caveat (2026-05-20 追記)**: 当初の refactor 案 (compiled 側でも boot module
内で `vm.eval("Lilac.start")`) は `lilac-compiled` wasm が `mruby-compiler` /
`mruby-eval` を含まない (build_config/lilac-compiled.rb で明示的に除外) ため
runtime error になることが `wsv dist` での動作確認で判明。target=compiled は
parser 制約により bundle 末尾 append の従来形が必須で、対称性は完全には
取れない。それでも target=full は boot helper layer (JS) で boot を fire し、
target=compiled は bytecode-embedded boot が走る、という二段は維持できる
(user 視点では「`Lilac.start` を書かない」契約は両 target で揃う)。

## 20.7 Boot pattern を上流選択として明文化 + Pattern A の 3 段グラデーション(2026-05-20)

§20.6 の boot helper layer 移譲を受けて、Lilac の運用設計の **上流判断** を
明文化する。これまで「単一 HTML か project 構造か」が user 側の最初の選択と
誤解されがちだったが、本質はそこではなく **boot pattern (A / B) の選択** が
最上位にあり、file 形式はその副産物。

### Pattern A / B の定義

- **Pattern A**: Lilac-provided boot helper(npm `@takahashim/lilac-full` の
  `boot()` / CLI inline bootstrap module / scaffold `boot.js` 等)が bridge
  を所有。`createVM` → user Ruby eval → `Lilac.start` の一連を helper が回す。
  user 側は **class 定義 + DOM だけ** 書く
- **Pattern B**: user が自前 `<script type="module">` で `createVM` から書き、
  `Lilac.start` も Ruby 側に明示で書く。`examples/runtime-only/*.html` がこの
  形。bridge layer の細部(wasm memory introspection, callback handle 数の
  expose 等)に踏み込む題材に向く

runtime は両 pattern で共通(§1 canonical 不変)、変わるのは **JS-side glue
だけ**。

### Pattern A の 3 段グラデーション

Pattern A の boot helper は **入手経路** で 3 段に分かれる。deployment intent
の順に低摩擦 → 高機能:

| 入手経路 | 例 | 向いている用途 |
|---|---|---|
| **CDN** | `import { boot } from "https://esm.sh/@takahashim/lilac-full"` | CodePen / 静的 host / 学習デモ / `<script>` タグ 2 つで動かせる最低摩擦パス |
| **npm install** | `import { boot } from "@takahashim/lilac-full"` | bundler / 自前 build pipeline 上で使う |
| **CLI `lilac build`** | builder が inline bootstrap (target=compiled) / scaffold `boot.js` (target=full) を emit | multi-page project + mrbc 経由の bundle size 最適化、project 構造前提 |

3 つとも boot helper layer の役割は同じ(`createVM` → script eval →
`Lilac.start`)。違うのは:

- **wasm の供給元**: CDN は package に同梱、npm はローカル `node_modules/`、
  CLI は `dist/vendor/lilac-compiled/` に CLI が auto-vendor
- **Ruby の供給形**: CDN / npm は inline `<script type="text/ruby">`、
  CLI target=compiled は `.mrb` bytecode
- **file 形式の前提**: CDN / npm は単一 HTML でも project でも可、CLI は
  project 構造を要求

### File 形式は下流

```
deployment intent  →  boot pattern (A or B)  →  file layout
   (どう動かす?)        (誰がbridgeを持つ?)      (単一HTML / project)
```

「7guis 形式 (project 構造) で書けば CLI で動く」は **必要条件だが本質ではない**。
本質は Pattern A を採用すること。理論上は単一 HTML + Pattern A も可
(`<script type="module">import { boot } from "..."; boot();</script>` だけで
完結)、project 構造 + Pattern B も可(各 page に自前 bridge を書く)だが、
後者は CLI と相性が悪い(自前 bridge と CLI bootstrap が衝突する)。

### 同一 file の dual-purpose は採らない

Pattern A と Pattern B が同じ HTML 内に共存すると以下の理由で破綻するため、
framework として dual-purpose 設計は採らない:

- `createVM` が 2 重に走り、wasm instance を 2 個立てる
- user 側 `<script type="module">` が `vm.evalScript("#ruby-source")` を呼ぶが、
  CLI compiled mode では既に script tag が strip されているため失敗
- Ruby 側で `JS.global[:__breakout_vm]` 経由で vm を取る pattern は、CLI 側
  の bootstrap が立てた別 vm を参照することになり整合性が崩れる

`examples/runtime-only/lilac-breakout.html` がまさにこのケースで、CLI に
そのまま通すと動かない。これは bug ではなく **設計上の境界**。CLI 化したい
場合は別 example として Pattern A 形式で書き直すのが筋。

### 影響

- **doc clarity**: 「CLI を使うべきか」の判断は file 形式の好みではなく
  deployment intent から導かれる boot pattern 選択の問題、と明確化
- **runtime-only example の役割**: Pattern B を見せる教育的サンプルとして
  存続意義が明示される。CLI が動かない HTML があっても "bug" ではない
- **将来 examples**: CDN 経由 demo を `examples/cdn/` に追加する余地が
  生まれる(npm publish 後の follow-up)。Pattern A 最低摩擦パスの実例

### 影響を受ける箇所

- `npm/lilac-full/index.js` の `boot()` を §20.6 に揃える(eval 末尾で
  `vm.eval("Lilac.start")`)。これで CDN / npm install 経由でも boot helper
  layer の責務契約が成立する
- `examples/runtime-only/lilac-breakout.html` 等は Pattern B のままで OK
  (CLI 化したい場合は別 example として作る)
- `lilac-design.md` / `lilac-spec.md` に Pattern A / B の区別を反映するのは
  follow-up(本決定は本 ADR 内に閉じる)

## 20.8 compiled mode でも `<script type="text/ruby">` を dist HTML に残す(2026-05-20)

§18 の初版実装では target=compiled の build で `<script type="text/ruby">`
要素を **dist HTML から strip** していた(`extract_inline_ruby_scripts` の
`stripped_html` 経路)。意図は「parser が無い compiled wasm では browser が
text/ruby を実行できないので残しても dead text、size 減らすために消そう」。

しかし以下の不利益が後から発覚:

- **source-display 系の introspection 機能が壊れる**: `examples/7guis` の
  `boot.js` は最初の `<script type="text/ruby">` を `<code id="source-display">`
  に mirror しているが、compiled では tag が消えているのでフォールバック
  placeholder("// Source is compiled into the .mrb bundle. Run the full target
  to see the original Ruby here.")を表示する分岐があった
- **target 間の HTML 非対称**: target=full / target=compiled で dist HTML の
  semantic が違う(同じ source から異なる HTML が出る)。"compiled は bytecode
  経由で動く版で、それ以外は同じ" という素直な理解が成立しない
- **view-source 体験**: compiled mode の page を開いた人が browser dev tools
  で view-source しても Ruby が見えない。Lilac の "Templates stay as valid
  HTML5 with `data-*` directives" / "Ruby + HTML を書いてブラウザで開く" 系の
  方針と整合しない

### 決定

**両 target で `<script type="text/ruby">` を dist HTML に保持する**。
`extract_inline_ruby_scripts` は引き続き `.mrb` バンドル用にソース文字列を
抽出するが、HTML の strip は行わない。

target=compiled での挙動:

- browser は `text/ruby` を unknown type として実行スキップ(副作用なし)
- 同 page に並ぶ inline boot module は `loadBytecode` だけを呼ぶので script
  tag を読まない
- script tag は完全に dead text として残る。size 増は数 KB レベルで、HTML
  gzip / brotli で圧縮されればさらに小さい(`.mrb` の "parser を wasm から削る"
  価値は不変)

### 影響

- `examples/7guis/public/boot.js` の compiled / full 分岐を統合: 両 target で
  同じ source-mirror 処理(`document.querySelector('script[type="text/ruby"]')`
  → `<code id="source-display">` にコピー)が動く
- target=full / target=compiled の dist HTML は **bootstrap module 部分以外
  bit-identical** に近づく(完全一致ではないが、user の書いた markup は同じ)
- 「production minify したい」需要は HTML minifier(htmlnano / html-minifier-terser
  等)を後段で挟む運用に委譲。CLI 側に `--strip-source` のような flag を入れる
  予定なし(判断責務を user に押し付けず、default は keep のみ)

### 影響を受ける箇所

- `cli/lib/lilac/cli/builder.rb`:
  - `build_page` の `html = extracted[:stripped_html] if @target == :compiled`
    を削除(`extracted[:scripts]` の取得は維持)
  - 関連コメントを「strip 廃止、両 target で keep」に更新
- `examples/7guis/public/boot.js`:
  - compiled branch の placeholder フォールバックを削除、source-mirror を
    両 target 共通で実行する形に整理
- `cli/test/test_builder.rb`:
  - `test_target_compiled_includes_page_inline_ruby_in_mrb` を「`.mrb` には
    含まれる **AND** HTML にも script tag が残る」を確認する形に更新
- 7guis の dist を再 build して compiled mode で source-display が表示される
  ことを確認済み

---
