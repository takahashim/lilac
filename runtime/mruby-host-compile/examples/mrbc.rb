#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal `mrbc` equivalent driven by mrbc-host.wasm via wasmtime-rb.
#
# Usage:
#   gem install wasmtime  # >= the version that exposes wasm_exceptions:
#   ruby examples/mrbc.rb input.rb output.mrb
#
# WASM path defaults to ../../../build/mrbc-host.wasm (the monorepo
# layout); override with MRBC_HOST_WASM=/abs/path.

require "wasmtime"

src_path = ARGV[0] or abort "usage: mrbc.rb input.rb output.mrb"
out_path = ARGV[1] or abort "usage: mrbc.rb input.rb output.mrb"

wasm_path = ENV.fetch("MRBC_HOST_WASM") do
  File.expand_path("../../../build/mrbc-host.wasm", __dir__)
end
abort "wasm not found: #{wasm_path}" unless File.file?(wasm_path)

engine = Wasmtime::Engine.new(wasm_exceptions: true)
mod = Wasmtime::Module.from_file(engine, wasm_path)
linker = Wasmtime::Linker.new(engine)
Wasmtime::WASI::P1.add_to_linker_sync(linker)
store = Wasmtime::Store.new(engine, wasi_p1_config: Wasmtime::WasiConfig.new)
instance = linker.instantiate(store, mod)
instance.export("_initialize").to_func.call

memory  = instance.export("memory").to_memory
alloc   = instance.export("mrbc_alloc").to_func
free_fn = instance.export("mrbc_free").to_func
compile = instance.export("compile_source").to_func

src = File.binread(src_path)
src_ptr = alloc.call(src.bytesize)
out_p, out_l = alloc.call(4), alloc.call(4)
err_p, err_l = alloc.call(4), alloc.call(4)
memory.write(src_ptr, src)

status = compile.call(src_ptr, src.bytesize, out_p, out_l, err_p, err_l)

case status
when 0
  irep_ptr = memory.read(out_p, 4).unpack1("l<")
  irep_len = memory.read(out_l, 4).unpack1("l<")
  File.binwrite(out_path, memory.read(irep_ptr, irep_len))
  free_fn.call(irep_ptr)
  warn "wrote #{out_path} (#{irep_len} bytes)"
when 1
  err_ptr = memory.read(err_p, 4).unpack1("l<")
  err_len = memory.read(err_l, 4).unpack1("l<")
  warn memory.read(err_ptr, err_len)
  free_fn.call(err_ptr) unless err_ptr.zero?
  exit 1
else
  warn "compile_source returned unexpected status=#{status}"
  exit 1
end

[src_ptr, out_p, out_l, err_p, err_l].each { |p| free_fn.call(p) }
