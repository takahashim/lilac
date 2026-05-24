# 14. Props P2: `prop` の意味拡張(ivar 宣言 + accessor + 値式)

## 14.1 判断

`prop :X, Type` の意味を、P1 の「値を `props.X` で読める static configuration」
から、次の 4 機能を一つの DSL で束ねる形に拡張する:

1. **`@X` Signal ivar の auto-init**(mount 時に `Signal.new(coerced_value)` を
   生成して `@X` に set。template から `@X` で直接参照可能)
2. **同名 public reader の auto-define**(`instance.X` で `@X.value` を返す
   accessor を `define_method` で生成)
3. **`data-prop-X` 値式の解決**(`data-prop-x="it.field"` / `data-prop-x="@ivar"`
   を parent の per-row scanner が clone-time に評価し、scalar を child の
   属性に書き戻す)
4. **mount-time override 検出**(setup 内で `@X = signal(...)` 等の reassign
   が起きたら Signal identity 比較で raise)

P1 の `props.X` accessor も back-compat として残す(read-through で `@X.value`
を返す)。詳細は `docs/lilac-props-spec.md` §3〜§8、§10.5。

## 14.2 背景

P1 完了直後の `examples/runtime-only/lilac-todo.html` の修正で、`<ul data-each="@items">
<li data-component="TodoItem">` の **per-row component** パターンが必要に
なった。子の中で `data-text="it.title"` と書きたいが、これは directive scanner
の boundary 規則(data-component subtree を child の Scanner に任せる)と
衝突 — child は parent の iteration item を知らないので resolve できない。

複数の代替案を比較した結果:

- 案A: `it` を child に貫通させる Iteration registry → component 境界の暗黙
  leak が将来の reactive props と概念衝突 → 不採用
- 案B: 新 directive family `data-bind-X="title"` → directive surface 拡大、
  `bind` (imperative API) と語呂が混乱 → 不採用
- 案C: テンプレ専用 namespace `props.X` (`data-text="props.title"`) → template
  syntax に新 namespace 追加が必要 → 不採用
- 案D (採用): **`prop :X` 自体に「`@X` ivar 宣言」を兼ねさせる** → 新 syntax
  追加ゼロ、`@X` 一本で値が読める。React/Vue の prop passing と同じ explicit
  data flow

## 14.3 判断の rationale

- **概念面積最小**: 「`@x` は signal、`it` は最寄り data-each の item、
  `data-prop-x` は親→子の prop 値」という 3 軸が直交。template 側は `@x` を
  「自分の signal」と理解すれば足り、ivar/prop の区別を意識しなくて済む
- **template syntax 不変**: `data-text="@x"` の既存 syntax を維持。新
  directive family も namespace も増えない
- **setup ergonomics**: `@title = signal(props.title)` のような boilerplate
  が消える(prop が自動で signal を作る)
- **React/Vue 慣行との整合**: 親→子は explicit な prop 渡し、子の中で完結
  (`it` 貫通のような暗黙 leak なし)
- **P3 (parent signal pass-through) への path**: Signal がすでに存在するので、
  parent signal の変化を effect で child の Signal に流す追加実装が自然
- **row reuse の reactive 更新**: bind_list が同一 key の row を再利用する際、
  parent scanner が `child.update_prop(name, value)` で Signal を mutate →
  既存 effect / computed が再評価される
- **override の早期検出**: `prop :title` と `@title = signal(...)` を user が
  両方書いてしまうと parent → child の reactive link が切れる。Signal の
  object identity 比較で mount 時に raise し、ヒント付きの error message
  (`@title.value = ...` / `@upper = computed { ... }` / rename) で誘導

## 14.4 トレードオフ

- **metaprog の使用箇所増**(§13 に反映済み): `define_method` + `instance_variable_set/get/defined?` が Component lifecycle に追加 — ただし全て
  framework 側 (`prop` DSL と mount hook) に集約、user code は触れない
- **mount lifecycle に +2 step**: `install_prop_ivars!` (Props.build 直後) と
  `validate_prop_ivars_not_overwritten!` (setup 直後)。lifecycle 全体が
  begin/rescue 連発になりやすいので `run_lifecycle_step(label) { ... }` の
  helper に統合(実装は `runtime/mruby-lilac/mrblib/lilac_component.rb` の
  `mount` 経路)
- **`@X` の意味二重性**: `@X` は ivar (user 定義) または prop (`prop :X` で
  auto-init) のいずれか。同名衝突は override 検出で raise されるので「両方
  存在する」状態は発生しないが、新規読者は「`@title` の出所」を判別するため
  に `prop :title` 宣言と setup を両方見る必要
- **value 式の制約**: `data-prop-x="@ivar"` は parent の setup より先に child
  の Props.build が走る case (non-data-each 配下) では `@ivar` 未定義時点で
  evaluate される → 現状未サポート(P3 候補)。`it.field` は data-each 配下
  のみで動く
- **CLI codegen 経路では `data-prop-X` の値式は未対応**: runtime canonical 経路
  のみで動く。CLI を経由したビルドは当面 lint で warn する必要(別 PR)

## 14.5 ステータス

確定・実装済み(2026-05-18 完了)。実装は以下:

- `runtime/mruby-lilac/mrblib/lilac_props.rb` — `Props.build` (Signal 生成のみ、
  host への書き込みなし)、`Props.coerce` 公開、read-through accessor
- `runtime/mruby-lilac/mrblib/lilac_component.rb` — `prop` DSL 拡張、
  `install_prop_ivars!` / `update_prop` / `validate_prop_ivars_not_overwritten!`、
  `defer_until_bound` / `each_binding_for` / `run_lifecycle_step` / `flush_deferred_until_bound!`、`component_for`
- `runtime/mruby-lilac-directives/mrblib/lilac_directives_scanner.rb` — `data-prop-*` の `resolve_props`、`extract_row_prop_exprs` / `push_prop_updates`、Component への `register_each_binding` 通知
- `runtime/mruby-lilac/mrblib/lilac_sortable.rb` — `make_sortable(by:)` 多態化、`sortable_target` 1 引数化 (registry 経由)

`examples/runtime-only/lilac-todo.html` / `examples/runtime-only/lilac-kanban.html` は新パターンを使う
形にリファクタ済み。P3 (parent signal pass-through) は `docs/lilac-props-spec.md`
§11 で記録、実需待ち。

---
