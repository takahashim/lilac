# mruby-host-compile

Lilac-internal mrbgem that exposes mruby's parser + codegen + bytecode
dumper as three wasm exports:

```c
int32_t compile_source(int32_t src_ptr, int32_t src_len,
                       int32_t out_ptr_outp, int32_t out_len_outp,
                       int32_t err_ptr_outp, int32_t err_len_outp);
int32_t mrbc_alloc(int32_t len);
void    mrbc_free(int32_t ptr);
```

Status codes from `compile_source`:

| status | meaning | output |
|---|---|---|
| 0 | ok | irep bytes in `out_ptr` / `out_len` |
| 1 | parse / compile error | utf-8 message in `err_ptr` / `err_len` |
| 2 | no compiler | wasm was built without `mruby-compiler` |

Purpose: let a Ruby host (`lilac-cli` via `wasmtime-rb`) drive
`mrbc-host.wasm` in place of an external `mrbc` binary. Lives in the
Lilac repo (not `mruby-wasm-runtime`) because the only consumer is the
Lilac CLI's wasmtime-driven build path.

The mrbgem is wired into `build_config/mrbc-host.rb`. Build the wasm
from the Lilac repo root:

```sh
make mrbc-host          # → build/mrbc-host.wasm
make mrbc-host-release  # → build/mrbc-host.release.wasm
```

The wasm uses the WebAssembly exception-handling proposal (mruby's
`setjmp`/`longjmp` lower through it), so the runtime must support it.

## Compile a .rb file to .mrb (drop-in `mrbc` replacement)

The `examples/mrbc.rb` script wraps the whole alloc / compile / read /
free dance into a one-shot CLI tool. Requires only `wasmtime` gem
(no lilac-cli):

```sh
gem install wasmtime  # or: bundle add wasmtime
ruby examples/mrbc.rb input.rb output.mrb
```

Looks for `build/mrbc-host.wasm` relative to the Lilac monorepo root
by default; override with `MRBC_HOST_WASM=/abs/path/to/mrbc-host.wasm`.

The same script also illustrates the full ABI usage in ~50 lines —
copy it as a starting point if you want to call the wasm from your own
Ruby code.

## Running via `wasmtime-rb` (raw)

```ruby
require "wasmtime"

engine = Wasmtime::Engine.new(wasm_exceptions: true)
mod = Wasmtime::Module.from_file(engine, "build/mrbc-host.wasm")

linker = Wasmtime::Linker.new(engine)
Wasmtime::WASI::P1.add_to_linker_sync(linker)
store = Wasmtime::Store.new(engine, wasi_p1_config: Wasmtime::WasiConfig.new)
instance = linker.instantiate(store, mod)
instance.export("_initialize").to_func.call

memory  = instance.export("memory").to_memory
alloc   = instance.export("mrbc_alloc").to_func
free_fn = instance.export("mrbc_free").to_func
compile = instance.export("compile_source").to_func

src     = "puts 42\n"
src_ptr = alloc.call(src.bytesize)
out_p, out_l = alloc.call(4), alloc.call(4)
err_p, err_l = alloc.call(4), alloc.call(4)
memory.write(src_ptr, src)

status = compile.call(src_ptr, src.bytesize, out_p, out_l, err_p, err_l)
irep_ptr = memory.read(out_p, 4).unpack1("l<")
irep_len = memory.read(out_l, 4).unpack1("l<")
irep = memory.read(irep_ptr, irep_len)  # starts with "RITE"

[src_ptr, out_p, out_l, err_p, err_l, irep_ptr].each { |p| free_fn.call(p) }
```

For a higher-level wrapper see `cli/lib/lilac/cli/wasm_mrbc_driver.rb`.
