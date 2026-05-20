# lilac-wasm-bin

Bundles the Lilac wasm runtimes (`lilac-full.wasm`, `lilac-compiled.wasm`)
and the `mruby-wasm-js` JS bridge as a single Ruby gem so that

```
gem install lilac-cli
lilac new my-app && cd my-app
bundle install
```

is enough to make both `lilac dev` and `lilac build` work — no `npm
install`, no manual `cp` of wasm files into `public/vendor/...`.

The scaffolded `Gemfile` declares `gem "lilac-wasm-bin"`, so the gem is
pulled transparently during `bundle install`. The `lilac-cli` gem
itself does **not** depend on this gem — projects that don't need the
bundled wasm (e.g. CI for an external runtime) can skip it without
penalty.

## Resolution

`lilac-cli`'s `CompiledRuntimeResolver` soft-requires `lilac/wasm/bin`
and consults `Lilac::Wasm::Bin.lilac_compiled_wasm` (and friends) when
discovering wasm. If the gem is absent the resolver falls back to the
existing env / config / monorepo / node_modules discovery chain.

## Layout

```
lilac-wasm-bin-X.Y.Z/
├── lib/lilac/wasm/bin.rb     # path constants + resolution helpers
└── data/                     # populated by `rake build:assets`
    ├── lilac-full.wasm
    ├── lilac-compiled.wasm
    └── mruby-wasm-js/        # JS bridge source
```

`data/` is gitignored and populated by `rake build:assets` immediately
before `gem build`. The gem build pipeline expects monorepo build
artifacts under `<monorepo>/build/` and `<monorepo>/mrbgem/mruby-wasm-js/`.

For monorepo development (when the gem is referenced as `gem
"lilac-wasm-bin", path: "../wasm-bin"`), the resolution helpers also
walk up to the monorepo `build/` directory as a fallback, so contributors
don't have to re-run `rake build:assets` after every wasm rebuild.
