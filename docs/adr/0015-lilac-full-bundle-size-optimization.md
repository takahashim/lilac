# 15. lilac-full の bundle size 最適化(browser-only 化 + explicit allow-list + -Oz)

## 15.1 判断

`build_config/lilac-full.rb` を以下の方針で最適化する:

1. **gembox 不使用、explicit allow-list 方式**: `default-no-stdio` gembox の
   暗黙取り込みをやめ、Lilac が実際に使う gem だけを 1 個ずつ `conf.gem`
   で列挙
2. **browser variant では `mruby-io` / `hal-wasi-io` / `mruby-wasi-dir` /
   `mruby-wasi-env` を含めない**(File / Dir / ENV / STDERR は browser で
   不要)
3. **`-Os` → `-Oz`**(compile time)。`-flto` は採用しない(LTO + sjlj の
   code-gen bug を回避)
4. **Logger の default emit 経路を `STDERR.puts` から `JS.global[:console].
   call(:warn/:error, ...)` に変更**(2 の前提条件)

## 15.2 背景

`lilac-full.release.wasm` の baseline は ~1,035 KB raw / 322 KB brotli。
JS framework(React+ReactDOM ~140 KB brotli、Vue ~60 KB、Solid ~7 KB)
と比べて重く、production 配信での bandwidth / parse cost が懸念。

bundle 内訳を `wasm-objdump -h` と `.o` / `.mrb` artifact 集計で測ったところ:

- mruby VM + stdlib: 約 70%
- mruby-wasm-js bridge: 約 10%
- mruby-regexp-compat: 約 10%
- Lilac gems(core / directives / form / router / async): 約 10%

stdlib 内では `mruby-math` / `mruby-rational` / `mruby-complex` / `mruby-
bigint` / `mruby-time` / `mruby-random` / `mruby-set` / `mruby-objectspace`
等が Lilac から **grep で使用箇所 0 hit**。`mruby-io` も `STDERR.puts` 1 箇所
を除いて未使用 — その 1 箇所も browser には `STDERR` 自体が存在しない。

`-flto` は `lilac-compiled` では効くが、`lilac-full` に含まれる `mruby-
compiler` / `mruby-eval` 由来の setjmp/longjmp 経路で LTO + `-mllvm
-wasm-enable-sjlj` lowering pass が code-gen bug を起こし、生成 wasm が
`LinkError: env.setjmp` または `WebAssembly.Exception` で instantiate 失敗。

## 15.3 判断の rationale

- gembox 暗黙取り込みは「使ってない gem も入る」を運用上気付きにくくする。
  explicit allow-list なら **追加した時に commit に載る**(decisions / spec
  と同じく可視化)
- browser variant の I/O / WASI 関連 gem は **存在自体が無意味**(`STDERR`
  も `File.open` も browser には無い)。Logger の出力先は `console.warn` /
  `console.error` が natural — JS bridge は既に Lilac 内で多用されており、
  追加の dependency にならない
- `-Oz` は `lilac-compiled` で既採用、production 安定性は確認済み。
  framework は interop crossing が支配的で CPU bound でないので `-Os` →
  `-Oz` の runtime cost はほぼ無視できる
- `-flto` は理論的にはさらに削減できるが、bug を回避する複雑な workaround
  (`-Wl,-mllvm,-wasm-enable-sjlj` 等)も runtime error を再発させた。
  原因は LTO codegen と sjlj lowering pass の相互作用と推定。**`lilac-
  compiled` だけ -flto、`lilac-full` は無し** という非対称を許容する

## 15.4 トレードオフ

- **明示列挙の保守コスト**: 新規利用者が「Hash#dig が使えない」「Set が無い」
  等で詰まる可能性。docs に「Lilac 同梱の Ruby stdlib subset」を明文化する
  必要(`docs/lilac-spec.md` に追記対象)
- **`-flto` 非採用による size の取りこぼし**: 推定 ~30-50 KB raw / ~10-20 KB
  brotli の potential 削減。LTO bug が将来 mruby / wasi-sdk のアップデート
  で解消されれば再評価
- **削除した gem の復活コスト**: 利用者の Ruby code が `Set` や `Time` を
  使い始めた場合、build_config に 1 行戻すだけだが、size 増分は把握済み
  (該当 gem の `.o` size を decision 内に参考値として記録した)

## 15.5 ステータス

確定・実装済み(2026-05-19 完了)。size 測定:

| stage | raw | brotli |
|---|---|---|
| baseline(gembox + `-Os`) | 1,035 KB | 322 KB |
| → explicit allow-list(stdlib trim、§15.1 の項目 1) | 887 KB | 272 KB |
| → mruby-io / WASI drop(項目 2 + 4) | 817 KB | 253 KB |
| → `-Oz` at link / compile(項目 3) | **773 KB** | **247 KB** |

**累積削減: raw −262 KB(−25.3%) / brotli −74 KB(−23.0%)**。
全 618 wasm_spec tests pass(無回帰)。

実装ファイル:
- `build_config/lilac-full.rb` — 全項目
- `Makefile` — `-Oz` を link 行にも適用
- `runtime/mruby-lilac/mrblib/lilac.rb` — Logger emit 経路を JS console に

`lilac-compiled` 側は既に同等の最適化(explicit list + `-Oz -flto`)が
入っていて、本判断は **lilac-full を lilac-compiled の polish レベルに
追従させた** 整理。

---
