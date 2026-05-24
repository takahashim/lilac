# 27. Package Handler を class-first API として整備 (class-first principle)

決定日: 2026-05-24

## 27.1 判断

Lilac は Ruby framework であり、**構造を要する単位は class / module / Struct で
表現する**ことを原則として明文化する。これは JS フレームワーク (composables /
hooks の function-based) との明確な差別化であり、Ruby を使う人にとって自然な
形を提供する。

具体的適用は **Package Handler API** に対して必須、その他は opportunistic:

- **公式 package API として class 化を必須にする部分**:
  - `Lilac::Directives::Handler` 基底 + `attribute "..."` macro + `def wire(ctx)`
  - Package 作者は class を書いて `Lilac::Directives::Scanner.register("Class::Name")`
    で登録
  - `register_directive(...) { block }` (現行 §23 / §25 の block API) は **廃止**
- **opportunistic に class 化する部分**:
  - 既存 `Codegen` の `emit_X` private method 群 → 必要に応じて
    `Lilac::CLI::Emitter` サブクラス化 (基底だけ用意して個別に migrate)
  - form_extension.rb の 3 emitter (`:form` / `:field` / `:button`) は class 化の
    最初の見本として実施
- **class 化しない部分** (= method のまま):
  - シンプルな `emit_text` / `emit_show_hide` 等 (~20 行)
  - Scanner の内部 dispatch ループ (`dispatch_text` 等)
  - 純粋な computation primitive (`signal { }` / `effect { }` / `computed { }`)
  - TagHook / CollectHook の register API (form 内部実装として block 維持、§27.4
    参照)

## 27.2 背景

§25 / §26 で package 配布形態を確立し、registration API (block) を運用してきた
結果、以下の構造的問題が見えた:

1. **block の中身が opaque**: package handler が `register_directive` block 内で
   `scanner.host.bind(scanner.wrap_ref(el), ...)` のように **scanner の内部 API
   を直接叩いている**。Lilac core を refactor すると全 package が壊れる
2. **block 形式は複雑な directive で破綻**: state や helper を closure で表現する
   必要があり、行数が増えるほど読みにくくなる
3. **test しにくい**: block を取り出して invoke する API がなく、外部から実行
   できない
4. **backtrace / debug 弱い**: anonymous proc として記録されるので、エラー時に
   どの directive かが判別困難
5. **Lilac の他の API は class-based** — `Lilac::Component` 継承、`Router` /
   `Resource` / `Fetchy` も class。directive handler だけ block なのは不整合

User からの観点整理 (2026-05-24):

> Ruby を使う人に使ってほしい framework なので、構造を持つ単位は class /
> Struct で表現するのが筋。JS/TS の composables / hooks との差別化ポイントでも
> ある。

これを **class-first principle** として明文化し、§27 で公式 package API に適用
する。

## 27.3 rationale

- **Ruby framework としての self-identity**: Rails / Hanami / Phoenix と同型の
  「class-based 公開 API」を貫徹。JS framework の port ではなく、Ruby ネイティブな
  framework として読める
- **OOP の利点が package 著者に届く**: ivar で state、private method で helper、
  inheritance で extension。Block では実現しにくい構造化を OOP が自然に提供する
- **stable な API surface**: 内部実装 (`scanner.host`, `scanner.evaluator` 等)
  への直接アクセスを Context 経由に切り替え、core refactor が package を壊さない
  形に
- **test しやすい / debug しやすい**: class.new.wire(ctx) で直接 invoke 可能。
  backtrace に method 名が出る。`Method#source_location` で内部 introspection 可
- **「内部 = method、外部 = class」境界の明確化**: Rails 等で確立した自然な
  pattern。framework maintainer が触る部分は柔軟、user が触る部分は安定 OOP

## 27.4 トレードオフ

- **trivial directive の verbosity 増**: 1 行 dispatch でも class + DSL +
  `def wire` の minimum 5 行が必要。block では 3 行で書けたものが膨らむ。ただし
  Rails の `class HomesController < ApplicationController; def index; end; end`
  と同程度のサイズで、Ruby 慣習として許容範囲
- **block API 廃止が breaking change**: 既存 package (extras / form の register
  call) は全部 class に書き換え。pre-release なので許容
- **TagHook / CollectHook を公式 package API にしない**:
  - 既存使用例が **form 内部のみ** (input/select/textarea の auto register)
  - 第三者の現実的な need が薄い
  - 公式 spec として固定化するより、form の implementation detail のまま残す方が
    future flexibility が高い
  - その代わり TagHook / CollectHook の API は **block-based のまま** で内部 use
    に限定 (= form maintainer が使う)
  - もし将来 3rd party が tag-level hook を本当に必要とする use case が出てきたら、
    §27 の延長として class 化を検討する
- **scanner の register_tag_hook / register_collect_hook の API は維持**:
  - 公開 spec ではなく form 内部の依存先
  - docs/lilac-package-spec.md には記載しない (= 公式 package API ではない)
- **built-in emit_X の class 化は強制しない**:
  - 単純なものを class 化すると boilerplate 増だけで実利薄
  - `Lilac::CLI::Emitter` 基底だけ用意し、複雑なもの (e.g., `emit_each` / `emit_on`)
    を必要に応じて opt-in で class 化
  - 現状の form_extension.rb の 3 emitter は class 化の **first example** として
    実施

## 27.5 実装

### 公開 API (Package 作者向け)

```ruby
# Handler 基底
class Lilac::Directives::Handler
  class << self
    attr_accessor :_attribute, :_phase

    def attribute(name = nil)
      name ? @_attribute = name.freeze : @_attribute
    end

    # optional, default :default
    def phase(value = nil)
      value ? @_phase = value : (@_phase || :default)
    end
  end

  def wire(ctx)
    raise NotImplementedError, "Handler subclass must implement #wire"
  end
end

# Context (Struct + 振る舞いメソッド)
class Lilac::Directives::Context
  attr_reader :attribute_name, :value, :element, :item

  def initialize(scanner:, component:, attribute_name:, value:, element:, item:)
    @scanner = scanner; @component = component
    @attribute_name = attribute_name; @value = value
    @element = element; @item = item
  end

  def iteration?; !@item.nil?; end
  def bind_attribute(name, to:); @component.bind(@element, attr: { name => to }); end
  def bind_text(to:); ...; end
  def bind_class(map_or_value); ...; end
  def bind_style(map_or_value); ...; end
  def on(event, &block); @element.on(event, &block); end
  def after_mount(&block); @component.after_mount(&block); end

  def advanced  # escape hatch、unstable
    @advanced ||= Advanced.new(@scanner, @component)
  end
end

# Registration (String で late-resolve、Rails の class_name: と同型)
Lilac::Directives::Scanner.register("Lilac::Extras::TooltipDirective")
```

### 内部 API (lilac-cli host 側、`Lilac::CLI::*` namespace)

```ruby
# Emitter 基底 (opt-in for class 化、必須ではない)
class Lilac::CLI::Emitter
  class << self
    def attribute(name = nil); ...; end
    def attribute_prefix(prefix = nil); ...; end  # built-in 用 (data-on-X 等)
  end

  def emit(directive, codegen_ctx); raise NotImplementedError; end
end

# Codegen.register(String)
Lilac::CLI::Codegen.register("Lilac::CLI::Form::FormEmitter")
```

### Package 作者向けの典型例

```ruby
# runtime/mruby-lilac-extras/mrblib/lilac_extras_tooltip.rb
module Lilac::Extras
  class TooltipDirective < Lilac::Directives::Handler
    attribute "data-tooltip"

    def wire(ctx)
      return unless ctx.value
      ctx.bind_attribute("title", to: ctx.value)
    end
  end
end

Lilac::Directives::Scanner.register("Lilac::Extras::TooltipDirective")
```

### Migration phase

| Phase | 内容 | 状態 |
|---|---|---|
| A | 本 §27 ドラフト | ✅ 2026-05-24 |
| B | `Lilac::Directives::Handler` + Context 実装、Scanner.register(String) 改修 | ✅ 2026-05-24 |
| C | `Lilac::CLI::Emitter` 基底新設 + Codegen.register(String) 改修 | ⏸️ **保留** (§27.6 参照) |
| D | 既存 extras (2 directive) を Handler class に書き換え | ✅ 2026-05-24 |
| E | 既存 form の runtime 側 (mrblib) を Handler class に書き換え (内部の TagHook / CollectHook は block 維持) | ✅ 2026-05-24 |
| F | 既存 form の CLI 側 (form_extension.rb) の 3 emitter を class 化 (class 化の見本) | ⚠️ **部分完了** (§27.6 参照) |
| G | scan_extensions の `except:` を attribute-name-string-list に変更 | ✅ 2026-05-24 |
| H | block-based `register_directive` の削除、test 全体の update | ✅ 2026-05-24 |
| I | docs/lilac-package-spec.md の全面 update、namespace 規約明記 | ✅ 2026-05-24 |
| J | parity-runner 等の動作確認 | ✅ 2026-05-24 |

実装中に当初 spec を超えて以下も完了 (= class-first principle の自然な拡張):

| 追加項目 | 内容 | 状態 |
|---|---|---|
| K | `COLLISION_PAIRS` を attribute-name 文字列に統一 (build-time/runtime 双方で同じ rule 表記) | ✅ 2026-05-24 |
| L | `Lilac::Directives::Compat` → `Lilac::Directives::Lints` rename (`compat.rb` → `lints.rb` / `compat_rules.rb` → `collision_rules.rb`) — `Compat` が CLI/runtime 互換性に誤読される問題を解消 | ✅ 2026-05-24 |
| M | form Wiring helpers を Context-only signature に refactor — `ctx.advanced.scanner` 依存を form 内部から完全除去 | ✅ 2026-05-24 |

総差分: 31 + 3 + 3 = 約 800 行 + 200 行追加。当初見積もり (~1000-1500) と概ね一致。

## 27.6 後続作業 (本決定スコープ外、trigger 待ち)

### 保留中の作業

- **Phase C: `Lilac::CLI::Emitter` 基底 + `Codegen.register(String)`** — 実質的な
  benefit (= attribute-name 統一) は Phase F の `register_emitter(:form,
  attribute: "data-form")` kwarg で達成済み。残るのは block→class の cosmetic
  変換のみ。build-time コードは Lilac maintainer + form gem 内部しか触らず
  3rd party use case が存在しないため、symmetric 化のためだけに ~200 行
  追加するのは ROI 負け。**「2 つ目の CLI emitter consumer が現れた時に着手」**
- **Phase F (部分完了)**: `EMITTER_ATTRIBUTES` の追加で attribute-name 化は完了。
  3 emitter 自体の class 化は Phase C と同根のため同じ判断で保留。

### Trigger 待ちの将来検討項目

- **built-in directive の opportunistic class 化** (`emit_each` / `emit_on` 等):
  ADR-0027 §27.4 で「強制しない」と明記済み。既存 method-based で機能していて、
  package 作者からは見えない。**Trigger**: 内部 refactor で複雑性が問題になった時
- **TagHook / CollectHook を公式 API として再評価**: 現在 form 内部のみで使用、
  3rd party use case 0 件。**Trigger**: 2 つ目の consumer (3rd party package or
  別の core 機能) が現れた時。speculation で API を固定するより design data point
  が揃ってから確定する方が良い
- **`attribute_prefix` を Handler 側にも追加するか**: 現状 Emitter 側にも未実装。
  built-in `data-on-X` / `data-attr-X` / `data-css-X` は scanner 内 case 分岐で
  処理されている。**Trigger**: 3rd party が `data-i18n-locale` のような prefix 型
  directive を書きたくなった時
- **`Lilac::Directives::Scanner.register` の error 戦略**: 未定義 class を register
  したとき、初 dispatch で `Lilac.logger.error` + skip が現状動作。**Trigger**:
  3rd party 作者から「typo が runtime まで発見されない」フィードバックが来た時、
  `lilac doctor` で startup 時 lint を実装

## 27.7 ステータス

**完了** (2026-05-24)。Phase B-J + 追加 K-M を実装、`make test-all` (487 CLI +
71 wasm-rb + 634 node + 5 parity scenarios) すべて green。

未実装の Phase C / F (class 化部分) および §27.6 後続項目は **trigger 待ち** として
本 ADR のスコープ外に確定。当面の実装は不要。

`lilac-cli` / `lilac-wasm-bin` の release は §25 の wasmtime-rb v45 release 待ち
のため、本 §27 は **master に landed 済み、release tagging 待ち** の状態。
