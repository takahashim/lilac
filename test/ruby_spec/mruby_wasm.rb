# frozen_string_literal: true

require "wasmtime"
require "json"

require_relative "dom/dispatch"
require_relative "dom/event"
require_relative "dom/scheduler"
require_relative "dom/observer"
require_relative "dom/promise"
require_relative "dom/storage"
require_relative "dom/fetch"
require_relative "dom/world"
require_relative "dom/document"
require_relative "dom/element"

# Minimal wasmtime-rb wrapper around lilac-full.wasm for use from
# Ruby-side test runners. Replaces the Node `runner.mjs` + JS bridge
# for the subset of specs that don't need DOM / async fibers.
#
# Provides:
#   vm = MrubyWasm.new(wasm_path: ..., args: [...])
#   vm.eval(ruby_source) # -> exit status (0 on success)
#   vm.stdout            # -> captured bytes since last flush
#   vm.stderr            # -> same for stderr
#
# Out of scope:
#   - Real JS object proxying (all `js.*` imports return zero handles)
#   - DOM / browser globals (the Spec framework's
#     `JS.global[:__test_failed__] = ...` writes go to a no-op handle)
#   - Fiber drain (specs that use `await` won't terminate cleanly)
#
# The minimal JS bridge is just enough that mruby-wasm-js can do its
# module init without crashing. User code that hits the bridge gets
# defaults (e.g. JS.global returns a handle, JS.global[:x] returns
# undefined-style nil, sets are no-ops).
class MrubyWasm
  class EvalError < StandardError; end

  # Default wasm_path points at the `lilac-full-host` variant (new EH
  # lowering) because wasmtime-rb's default config rejects the legacy
  # EH used by the browser-facing `lilac-full.wasm`. See
  # `build_config/lilac-full.rb` for the variant split.
  DEFAULT_WASM_PATH = File.expand_path("../../build/lilac-full-host.wasm", __dir__)

  def initialize(wasm_path: DEFAULT_WASM_PATH, args: ["lilac-wasm"], env: {})
    @wasm_path = wasm_path
    @args = args
    @env = env
    @stdout_buf = String.new(encoding: Encoding::BINARY)
    @stderr_buf = String.new(encoding: Encoding::BINARY)
    # JS handle table — minimal browser surface:
    #   id 0 = undefined / null sentinel
    #   id 1 = the global object (MrubyWasm::Dom::Window instance —
    #          dispatches via the `__js_get__` duck-typed protocol,
    #          gives access to document / console / Object / Array /
    #          JSON via property reads)
    #   id 2 = console      (sentinel) — log / warn / error → buffers
    #   id 3 = Object       (sentinel) — `new Object`, `Object.keys(o)`
    #   id 4 = Array        (sentinel) — `new Array`, instanceof check
    #   id 5 = JSON         (sentinel) — parse / stringify via Ruby JSON
    # Primitives (Integer / Float / String / true / false / nil),
    # Ruby Hashes / Arrays get stored under user handles ≥ 100.
    # Dom::Document / Dom::Element instances also live here once
    # accessed via the bridge.
    @handles = {
      0 => nil,
      1 => Dom::Window.new(self),
      2 => :console,
      3 => :object_ctor,
      4 => :array_ctor,
      5 => :json_ctor,
    }
    @next_handle = 100
    # @pending_error holds a JS-side exception object (handle id) that
    # the wasm picks up via the `js_take_error` import. Any exception
    # raised inside js_call / js_new while executing host-side Ruby
    # gets routed here so mruby surfaces it as JS::Error instead of
    # crashing the host.
    @pending_error = 0
    boot!
  end

  attr_reader :wasm_path

  # Evaluate Ruby source inside the wasm. The source string is passed
  # via a handle (the same protocol the JS bridge uses); our JS stubs
  # back the handle table with a Ruby Hash so the wasm's
  # js_to_string_len / js_to_string_copy reads see the bytes.
  #
  # Returns mruby's exit code: 0 on success, 1 on parse/runtime error,
  # 2 if the compiler is absent (lilac-compiled variant).
  def eval(source)
    handle = store_handle(source.b)
    rc = @js_eval_handle.call(handle, 0, 0)
    # Drain pending microtasks + timers so fibers suspended on `.await`
    # finish before the next eval. We advance through each pending
    # timer's due_at one at a time (chained timers / promise then-then
    # cascades all settle in this loop). Cap at 1000 iterations to
    # guard against pathological infinite-timer recursion.
    drain_async!
    rc
  ensure
    @handles.delete(handle) if handle
  end

  # Advance the test scheduler clock to fire each pending timer in
  # order, draining microtasks at each step. Bounded to avoid
  # runaways.
  def drain_async!(max_iterations: 1000)
    window = @handles[1]
    return unless window.respond_to?(:scheduler)

    scheduler = window.scheduler
    scheduler.drain_microtasks
    max_iterations.times do
      next_at = scheduler.next_due_timer_at
      break if next_at.nil?

      scheduler.advance_time([next_at - scheduler.now_ms, 0].max)
    end
  end

  # Store bytes/string under a fresh handle id; the wasm reads it back
  # through js_to_string_len + js_to_string_copy.
  def store_handle(value)
    id = @next_handle
    @handles[id] = value
    @next_handle += 1
    id
  end

  # Map a `__js_get__` / `__js_call__` return value to a handle id.
  # Well-known sentinel symbols (`:console` / `:object_ctor` / etc.)
  # reuse their boot-time handle so wasm-side `JS.global[:console]`
  # always sees the same id; other values get fresh handles. The
  # accumulation isn't currently reclaimed — see Session 6's drain
  # work for the eventual `js_release` impl.
  def handle_for(value)
    case value
    when nil          then 0
    when :console     then 2
    when :object_ctor then 3
    when :array_ctor  then 4
    when :json_ctor   then 5
    else store_handle(value)
    end
  end

  def invoke_callback(callback_id, args)
    args_handle = store_handle(args)
    result_handle = @js_invoke_proc.call(callback_id, args_handle)
    @handles[result_handle]
  ensure
    @handles.delete(args_handle) if args_handle
    if result_handle && result_handle >= 100
      @handles.delete(result_handle)
    end
  end

  def advance_time(ms)
    window = @handles[1]
    return nil unless window.respond_to?(:scheduler)

    window.scheduler.advance_time(ms)
  end

  def drain_microtasks
    window = @handles[1]
    return nil unless window.respond_to?(:scheduler)

    window.scheduler.drain_microtasks
  end

  # Drain + return captured stdout. Clears the internal buffer.
  def stdout
    out = @stdout_buf
    @stdout_buf = String.new(encoding: Encoding::BINARY)
    out
  end

  def stderr
    out = @stderr_buf
    @stderr_buf = String.new(encoding: Encoding::BINARY)
    out
  end

  private

  def boot!
    @engine = Wasmtime::Engine.new(wasm_exceptions: true)
    @module = Wasmtime::Module.from_file(@engine, @wasm_path)

    linker = Wasmtime::Linker.new(@engine)
    register_js_stubs(linker)
    register_wasi(linker)

    @store = Wasmtime::Store.new(@engine, wasi_p1_config: Wasmtime::WasiConfig.new)
    @instance = linker.instantiate(@store, @module)

    @memory = @instance.export("memory").to_memory

    init = @instance.export("_initialize")&.to_func
    init&.call

    @mrbc_alloc_fn      = @instance.export("mrbc_alloc")&.to_func
    @mrbc_free_fn       = @instance.export("mrbc_free")&.to_func
    @compile_source     = @instance.export("compile_source")&.to_func
    @js_invoke_proc     = @instance.export("js_invoke_proc")&.to_func
    @js_eval_handle     = @instance.export("js_eval_handle")&.to_func
    @js_load_irep_handle = @instance.export("js_load_irep_handle")&.to_func

    raise "lilac-full.wasm is missing compile_source export" unless @compile_source
    raise "lilac-full.wasm is missing js_load_irep_handle export" unless @js_load_irep_handle
  end

  # All 25 `js.*` imports get stubbed. Signatures must match
  # lilac-full-host.wasm's import table exactly — verified via
  # `wasm-objdump -j Import -x build/lilac-full-host.wasm`. Functional
  # behavior is minimal; pure-mruby specs that don't touch JS run
  # cleanly with these defaults.
  def register_js_stubs(linker)
    define = ->(name, params, results, &body) do
      linker.func_new("js", name, params, results, &body)
    end

    # (src_ptr, src_len) -> handle. Minimal JS evaluator — recognizes
    # the three literal sources that mruby-wasm-js's `JS.wrap` uses
    # for true / false / null. Anything else returns 0 (= undefined).
    # A real JS engine isn't shipped, so user-side `JS.eval("...")` won't
    # work, but the wrap path that test fixtures depend on does.
    define.call("js_eval", [:i32, :i32], [:i32]) do |caller, p, l|
      src = read_mem_str(caller, p, l).strip
      handle_for(evaluate_js_source(src))
    end
    # () -> handle (= the global object)
    define.call("js_global", [], [:i32]) { |_c| 1 }
    # (handle) -> ()
    define.call("js_release", [:i32], []) { |_c, _h| nil }
    # (handle, key_ptr, key_len) -> handle. Property access on the
    # handle's underlying Ruby value:
    #   global[:console / :Object / :Array / :JSON]   → sentinels
    #   array[:length]                                 → number handle
    #   array["3"] (numeric-string index)              → element handle
    #   hash["a"]                                      → value handle
    define.call("js_get", [:i32, :i32, :i32], [:i32]) do |caller, h, p, l|
      key = read_mem_str(caller, p, l)
      v = @handles[h]
      # DOM dispatch first — Window / Document / Element etc.
      next handle_for(v.__js_get__(key)) if v.respond_to?(:__js_get__)

      case v
      when Array
        if key == "length"
          store_handle(v.size)
        elsif (idx = Integer(key, exception: false))
          val = v[idx]
          val.nil? ? 0 : store_handle(val)
        else
          0
        end
      when Hash
        v.key?(key) ? store_handle(v[key]) : 0
      else
        0
      end
    end
    # (handle, key_ptr, key_len, value_handle) -> ().
    # Writes to underlying Hash / Array so JS.object / JS.array can
    # build up a value the bridge sees as JS-like.
    define.call("js_set", [:i32, :i32, :i32, :i32], []) do |caller, h, p, l, v|
      key = read_mem_str(caller, p, l)
      target = @handles[h]
      value = @handles[v]
      if target.respond_to?(:__js_set__)
        target.__js_set__(key, value)
      else
        case target
        when Hash
          target[key] = value
        when Array
          idx = Integer(key, exception: false)
          target[idx] = value if idx
        end
      end
      nil
    end
    # (handle, method_ptr, method_len, args_ptr, arg_count) -> handle.
    # Routes JS method calls:
    #   console.{log,info} → stdout buffer
    #   console.{warn,error} → stderr buffer
    #   JSON.parse(str) → wraps Ruby JSON.parse result
    #   JSON.stringify(obj) → wraps Ruby JSON.generate result
    #   Object.keys(obj) → array of hash keys
    #   array.push(v) → Array#push (returns new length)
    define.call("js_call", [:i32, :i32, :i32, :i32, :i32], [:i32]) do |caller, h, mp, ml, ap, ac|
      method = read_mem_str(caller, mp, ml)
      args = read_handle_args(caller, ap, ac)
      target = @handles[h]
      begin
        if target.respond_to?(:__js_call__)
          handle_for(target.__js_call__(method, args))
        else
          dispatch_js_call(target, method, args)
        end
      rescue => e
        # JS errors surface to mruby via js_take_error on next bridge
        # hit; the wasm-side throws JS::Error. We can't raise out of a
        # wasmtime-rb host callback (would unwind the wasm runtime).
        @pending_error = store_handle("#{e.class}: #{e.message}")
        0
      end
    end
    # (handle, args_ptr, args_count) -> handle.
    # `new Object` / `new Array` produce fresh Hash / Array under a new
    # handle so subsequent js_set / js_call writes have somewhere to
    # land. Other constructors are unsupported here (return 0).
    define.call("js_new", [:i32, :i32, :i32], [:i32]) do |caller, ctor, ap, ac|
      args = read_handle_args(caller, ap, ac)
      target = @handles[ctor]
      value =
        if target.respond_to?(:__js_new__)
          target.__js_new__(args)
        else
          case target
          when :object_ctor then {}
          when :array_ctor  then []
          else nil
          end
        end
      handle_for(value)
    end
    # (handle) -> length. Honors host-registered byte buffers so eval
    # source / irep bytes can flow into the wasm via the handle table.
    define.call("js_to_string_len", [:i32], [:i32]) do |_c, h|
      string_value_for(@handles[h]).bytesize
    end
    # (handle, dst_ptr, dst_len) -> (). Writes the registered bytes
    # into linear memory at dst_ptr (up to dst_len).
    define.call("js_to_string_copy", [:i32, :i32, :i32], []) do |caller, h, ptr, len|
      value = string_value_for(@handles[h])
      if len.positive?
        mem = caller.export("memory").to_memory
        mem.write(ptr, value.byteslice(0, len))
      end
      nil
    end
    # (src_ptr, src_len) -> handle. Registers the wasm-side bytes as a
    # host handle so subsequent js_call args / js_to_string_* reads can
    # surface them back.
    define.call("js_from_string", [:i32, :i32], [:i32]) do |caller, p, l|
      str = read_mem_str(caller, p, l)
      store_handle(str)
    end
    # (handle) -> int
    define.call("js_to_int", [:i32], [:i32]) { |_c, h| Integer(@handles[h] || 0) }
    # (int) -> handle
    define.call("js_from_int", [:i32], [:i32]) { |_c, n| store_handle(n) }
    # (handle) -> float
    define.call("js_to_float", [:i32], [:f64]) { |_c, h| Float(@handles[h] || 0.0) }
    # (float) -> handle
    define.call("js_from_float", [:f64], [:i32]) { |_c, x| store_handle(x) }
    # (handle) -> bool. True if the handle's value is JS null/undefined.
    # @handles[0] is nil by construction (the undefined sentinel);
    # missing keys also resolve to nil.
    define.call("js_is_null", [:i32], [:i32]) { |_c, h| @handles[h].nil? ? 1 : 0 }
    # (handle, handle) -> bool
    define.call("js_strict_equal", [:i32, :i32], [:i32]) do |_c, a, b|
      @handles[a] == @handles[b] ? 1 : 0
    end
    # (handle) -> length of typeof result string
    define.call("js_typeof_len", [:i32], [:i32]) { |_c, h| typeof_for(@handles[h]).bytesize }
    # (handle, dst_ptr, dst_len) -> () — copies typeof string into memory
    define.call("js_typeof_copy", [:i32, :i32, :i32], []) do |caller, h, p, l|
      s = typeof_for(@handles[h]).byteslice(0, l)
      caller.export("memory").to_memory.write(p, s)
      nil
    end
    # (handle) -> length
    define.call("js_inspect_len", [:i32], [:i32]) { |_c, h| @handles[h].inspect.bytesize }
    # (handle, dst_ptr, dst_len) -> ()
    define.call("js_inspect_copy", [:i32, :i32, :i32], []) do |caller, h, p, l|
      s = @handles[h].inspect.byteslice(0, l)
      caller.export("memory").to_memory.write(p, s)
      nil
    end
    # (handle, ctor_handle) -> bool. Currently only Array detection.
    define.call("js_instanceof", [:i32, :i32], [:i32]) do |_c, h, ctor|
      if @handles[ctor] == :array_ctor && @handles[h].is_a?(Array)
        1
      elsif @handles[ctor] == :object_ctor && @handles[h].is_a?(Hash)
        1
      else
        0
      end
    end
    # (callback_id) -> callback_handle. The wasm side stores the Ruby
    # Proc in its callback table under callback_id; the host returns a
    # JS-callable wrapper object that routes invocations back through
    # the exported `js_invoke_proc(callback_id, args_handle)`.
    define.call("js_make_callback", [:i32], [:i32]) do |_c, callback_id|
      store_handle(Dom::Callback.new(self, callback_id))
    end
    # () -> count
    define.call("js_handle_count", [], [:i32]) { |_c| @handles.size }
    # (handle) -> handle
    define.call("js_clone", [:i32], [:i32]) { |_c, h| h }
    # () -> error_handle. Returns the most recent host-side exception
    # captured during js_call/js_new (or 0 if none) and clears it.
    # See @pending_error initialization for the rationale.
    define.call("js_take_error", [], [:i32]) do |_c|
      err = @pending_error
      @pending_error = 0
      err
    end
  end

  # Hook WASI fd_write to capture stdout/stderr, route everything
  # else through wasmtime's default WASI::P1.
  def register_wasi(linker)
    # Default WASI adds fd_close / fd_fdstat_get / fd_seek / fd_write /
    # args_*. We need fd_write to capture per-fd, so we add the full
    # WASI set first then shadow fd_write with our own.
    Wasmtime::WASI::P1.add_to_linker_sync(linker)

    # Allow shadowing for our fd_write override.
    linker.allow_shadowing = true
    linker.func_new(
      "wasi_snapshot_preview1", "fd_write",
      [:i32, :i32, :i32, :i32], [:i32]
    ) do |caller, fd, iovs_ptr, iovs_count, nwritten_ptr|
      total = 0
      mem = caller.export("memory").to_memory
      buf = fd == 2 ? @stderr_buf : @stdout_buf
      iovs_count.times do |i|
        base = iovs_ptr + (i * 8)
        ptr = mem.read(base, 4).unpack1("l<")
        len = mem.read(base + 4, 4).unpack1("l<")
        buf << mem.read(ptr, len) if len.positive?
        total += len
      end
      mem.write(nwritten_ptr, [total].pack("l<"))
      0
    end
  end

  def mrbc_alloc(n)
    @mrbc_alloc_fn.call(n)
  end

  def mrbc_free(p)
    @mrbc_free_fn.call(p) unless p.zero?
  end

  def free_all(*ptrs)
    ptrs.each { |p| mrbc_free(p) }
  end

  def read_i32(ptr)
    @memory.read(ptr, 4).unpack1("l<")
  end

  # Read a UTF-8 string from linear memory. Used by the JS bridge stubs
  # that take (ptr, len) pairs (js_get key, js_call method, js_from_string).
  def read_mem_str(caller, ptr, len)
    return "" if len <= 0

    mem = caller.export("memory").to_memory
    mem.read(ptr, len).force_encoding("UTF-8")
  end

  # Read `count` i32 handle ids from the args buffer (each 4 bytes,
  # little-endian) and dereference each through @handles. Used by
  # js_call / js_new to surface Ruby values to the dispatch logic.
  def read_handle_args(caller, ptr, count)
    return [] if count.zero?

    mem = caller.export("memory").to_memory
    raw = mem.read(ptr, count * 4)
    raw.unpack("l<*").map { |h| @handles[h] }
  end

  # JS `typeof` semantics, mapped from Ruby classes. Matches the
  # spec_helper's expectations:
  #   nil      → "object" (typeof null === "object" in JS)
  #   Integer  → "number"
  #   Float    → "number"
  #   String   → "string"
  #   true/false → "boolean"
  #   Hash / Array / Symbol sentinels → "object"
  def typeof_for(value)
    case value
    when nil               then "object"
    when Integer, Float    then "number"
    when String            then "string"
    when true, false       then "boolean"
    when Dom::Callback, Dom::Constructor, Dom::PromiseConstructor
      "function"
    else                        "object"
    end
  end

  # Dispatch a JS method call to a host-side Ruby value. Returns the
  # handle of the result (or 0 for void/unsupported).
  def dispatch_js_call(target, method, args)
    case target
    when :console
      console_log(method, args)
      0
    when :json_ctor
      case method
      when "parse"     then store_handle(JSON.parse(args.first.to_s))
      when "stringify" then store_handle(JSON.generate(args.first))
      else 0
      end
    when :object_ctor
      # Object.keys(obj) — static method on the Object sentinel.
      method == "keys" && args.first.is_a?(Hash) ? store_handle(args.first.keys) : 0
    when :array_ctor
      # Array.from(iterable) — used by Fetchy to materialize header
      # entries into a Ruby array. Accepts existing Array (Headers
      # `.entries` returns one) or anything #to_a'able.
      if method == "from"
        case args.first
        when Array then store_handle(args.first.dup)
        when Hash then store_handle(args.first.to_a)
        else
          if args.first.respond_to?(:to_a)
            store_handle(args.first.to_a)
          else
            store_handle([])
          end
        end
      else
        0
      end
    when Array
      case method
      when "push" then args.each { |a| target.push(a) }; store_handle(target.size)
      else 0
      end
    else
      0
    end
  end

  def console_log(method, args)
    buf = (method == "error" || method == "warn") ? @stderr_buf : @stdout_buf
    args.each { |a| buf << (a.is_a?(String) ? a : a.to_s) << "\n" }
  end

  def string_value_for(value)
    case value
    when String then value
    when true then "true"
    when false then "false"
    when Integer, Float then value.to_s
    when Dom::ErrorValue then value.to_s
    else ""
    end
  end

  def evaluate_js_source(src)
    # Pattern: `setTimeout(() => globalThis.X.method(), delay)` —
    # commonly used by Fetchy specs to schedule an abort. We can't
    # interpret arbitrary JS, but this specific shape can be lifted
    # into a host-side scheduler.set_timeout call.
    if (m = src.match(/setTimeout\(\(\)\s*=>\s*globalThis\.(\w+)\.(\w+)\(\)\s*,\s*(\d+)\)/))
      target_key, method_name, delay = m[1], m[2], m[3].to_i
      window = @handles[1]
      target = window.respond_to?(:globals) ? window.globals[target_key] : nil
      if target.respond_to?(:__js_call__) && window.respond_to?(:scheduler)
        window.scheduler.set_timeout(
          ->(*_args) { target.__js_call__(method_name, []) },
          delay
        )
      end
      # The original returns `null` so the test's installer chain works.
      return nil
    end

    value = parse_js_expression(src)
    return value unless value == :__unsupported__

    parse_js_constructor(src)
  end

  def parse_js_expression(src)
    code = strip_wrapping_parens(src.strip)
    return true if code == "true"
    return false if code == "false"
    return nil if code == "null" || code == "undefined"
    return code[1..-2] if quoted_string?(code)
    return code.to_i if code.match?(/\A-?\d+\z/)
    return code.to_f if code.match?(/\A-?\d+\.\d+\z/)

    if (match = code.match(/\APromise\.(resolve|reject)\((.*)\)\z/m))
      ctor = @handles[1].__js_get__("Promise")
      value = parse_js_expression(match[2].strip)
      return ctor.__js_call__(match[1], [value == :__unsupported__ ? nil : value])
    end

    if code.start_with?("[") && code.end_with?("]")
      inner = code[1...-1].strip
      return [] if inner.empty?

      return split_top_level(inner).map { |part| parse_js_expression(part) }
    end

    if code.start_with?("{") && code.end_with?("}")
      inner = code[1...-1].strip
      return {} if inner.empty?

      return split_top_level(inner).each_with_object({}) do |entry, hash|
        key_src, value_src = split_object_entry(entry)
        return :__unsupported__ unless key_src && value_src

        key = parse_object_key(key_src)
        value = parse_js_expression(value_src)
        return :__unsupported__ if key.nil? || value == :__unsupported__

        hash[key] = value
      end
    end

    :__unsupported__
  end

  def parse_js_constructor(src)
    code = src.strip
    window = @handles[1]

    if code == "new EventTarget()"
      return Dom::StandaloneEventTarget.new
    end

    if (match = code.match(/\Anew Event\((.+)\)\z/m))
      arg = parse_js_expression(match[1].strip)
      return Dom::Event.new(arg)
    end

    if (match = code.match(/\Anew Error\((.+)\)\z/m))
      arg = parse_js_expression(match[1].strip)
      return Dom::ErrorValue.new(arg)
    end

    if (match = code.match(/\Anew Promise\(r => setTimeout\(r, (\d+)\)\)\z/m))
      return delayed_promise(window, match[1].to_i, nil)
    end

    if (match = code.match(/\Anew Promise\(\(resolve\) => setTimeout\(\(\) => resolve\((.+)\), (\d+)\)\)\z/m))
      value = parse_js_expression(match[1].strip)
      return delayed_promise(window, match[2].to_i, value)
    end

    nil
  end

  def delayed_promise(window, delay_ms, value)
    promise = Dom::PromiseValue.new(window)
    window.scheduler.set_timeout(proc { promise.fulfill(value) }, delay_ms)
    promise
  end

  def strip_wrapping_parens(src)
    loop do
      break src unless src.start_with?("(") && src.end_with?(")")
      inner = src[1...-1].strip
      break src unless balanced_delimiters?(inner)

      src = inner
    end
    src
  end

  def quoted_string?(src)
    (src.start_with?('"') && src.end_with?('"')) ||
      (src.start_with?("'") && src.end_with?("'"))
  end

  def split_top_level(src, delimiter = ",")
    parts = []
    current = +""
    depth = 0
    quote = nil
    escape = false

    src.each_char do |char|
      if quote
        current << char
        if escape
          escape = false
        elsif char == "\\"
          escape = true
        elsif char == quote
          quote = nil
        end
        next
      end

      case char
      when "'", '"'
        quote = char
        current << char
      when "{", "[", "("
        depth += 1
        current << char
      when "}", "]", ")"
        depth -= 1
        current << char
      else
        if char == delimiter && depth.zero?
          parts << current.strip
          current = +""
        else
          current << char
        end
      end
    end

    parts << current.strip unless current.empty?
    parts
  end

  def split_object_entry(entry)
    depth = 0
    quote = nil
    escape = false

    entry.each_char.with_index do |char, index|
      if quote
        if escape
          escape = false
        elsif char == "\\"
          escape = true
        elsif char == quote
          quote = nil
        end
        next
      end

      case char
      when "'", '"'
        quote = char
      when "{", "[", "("
        depth += 1
      when "}", "]", ")"
        depth -= 1
      when ":"
        return [entry[0...index].strip, entry[(index + 1)..].strip] if depth.zero?
      end
    end

    nil
  end

  def parse_object_key(src)
    key = strip_wrapping_parens(src.strip)
    return key[1..-2] if quoted_string?(key)
    return key if key.match?(/\A[$A-Za-z_][$\w]*\z/)

    nil
  end

  def balanced_delimiters?(src)
    depth = 0
    quote = nil
    escape = false

    src.each_char do |char|
      if quote
        if escape
          escape = false
        elsif char == "\\"
          escape = true
        elsif char == quote
          quote = nil
        end
        next
      end

      case char
      when "'", '"'
        quote = char
      when "{", "[", "("
        depth += 1
      when "}", "]", ")"
        depth -= 1
        return false if depth.negative?
      end
    end

    depth.zero? && quote.nil?
  end
end
