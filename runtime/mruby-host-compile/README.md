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

Purpose: let a Ruby host (`lilac-cli` via `wasmtime-rb`) drive
`lilac-full.wasm` in place of an external `mrbc` binary. The host
allocates a buffer via `mrbc_alloc`, writes Ruby source bytes, calls
`compile_source`, reads back irep bytes from the returned pointer, then
`mrbc_free`s both buffers.

Lives in the Lilac repo (not `mruby-wasm-runtime`) because the only
consumer is the Lilac CLI's wasmtime-driven build path — outside that
context the exports have no use. The mrbgem is wired into
`build_config/lilac-full.rb` only; the `lilac-compiled` variant doesn't
include it (and wouldn't compile usefully without `mruby-compiler`).

See `docs/lilac-proposals.md` ("`lilac-wasm-bin` gem: rubygems で
`lilac build` まで完結させる") for the broader distribution story.
