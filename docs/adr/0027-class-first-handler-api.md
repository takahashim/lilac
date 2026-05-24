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

| Phase | 内容 |
|---|---|
| A | 本 §27 ドラフト |
| B | `Lilac::Directives::Handler` + Context 実装、Scanner.register(String) 改修 |
| C | `Lilac::CLI::Emitter` 基底新設 + Codegen.register(String) 改修 |
| D | 既存 extras (2 directive) を Handler class に書き換え |
| E | 既存 form の runtime 側 (mrblib) を Handler class に書き換え (内部の TagHook / CollectHook は block 維持) |
| F | 既存 form の CLI 側 (form_extension.rb) の 3 emitter を class 化 (class 化の見本) |
| G | scan_extensions の `except:` を attribute-name-string-list に変更 |
| H | block-based `register_directive` の削除、test 全体の update |
| I | docs/lilac-package-spec.md の全面 update、namespace 規約明記 |
| J | parity-runner 等の動作確認 |

合計 ~1000-1500 行差分見込み。

## 27.6 後続作業 (本決定スコープ外)

- **built-in directive の opportunistic class 化**: `emit_each` / `emit_on` 等の
  複雑なものを必要に応じて class 化。優先度は低い (= 既存 method-based で機能
  しているもの)
- **TagHook / CollectHook を公式 API として再評価**: 3rd party の use case が
  出てきたら §27 の延長として class 化を検討
- **`attribute_prefix` を Handler 側にも追加するか**: 現状は Emitter 側のみ
  (built-in 用)。package 側に需要が出たら検討 (= 3rd party が data-X-Y 形式の
  directive を書きたくなったとき)
- **`Lilac::Directives::Scanner.register` の error 戦略**: 未定義 class を register
  したとき、初 dispatch で `Lilac.logger.error` + skip するが、startup 時の lint
  (lilac doctor) で早期発見させるかどうか

## 27.7 ステータス

着手 (2026-05-24)。Phase A 完了後、B 〜 J を順次実装。

`lilac-cli` / `lilac-wasm-bin` の release は §25 の wasmtime-rb v45 release 待ち
のため、本 §27 の実装は **release path 整備と並行で進められる** (実装 → release
タイミングまでに master に landed)。
