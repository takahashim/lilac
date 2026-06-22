# frozen_string_literal: true

require "dommy"
require "dommy/js/quickjs"

# Real-JS engine backing the wasmtime-rb test runner's JS bridge.
#
# mruby-in-wasm reaches the host through ~25 `js_*` imports that operate on
# opaque JS *handles*: js_eval / js_global / js_get / js_set / js_call / js_new /
# js_make_callback / .... In the browser those go to V8; here they go to a
# QuickJS engine bound to a Dommy DOM (dommy-js-quickjs's WasmBridge), so the
# Ruby inner loop runs the *same* JavaScript a browser would instead of the
# literal-only stub evaluator MrubyWasm used before.
#
# The single global JS world (case "A" of the migration plan): quickjs owns
# globalThis, Dommy's window/document are installed into it, and the guest's
# `JS.global` IS quickjs globalThis. So a fetch stub the spec installs with
# `JS.eval_javascript("globalThis.fetch = …")` and the fetch Fetchy calls are
# the same function — no split brain.
#
# Integration is deliberately thin: every JS value crosses as a JsRef that
# implements the bridge ABI (__js_get__/__js_set__/__js_call__/__js_new__), so
# MrubyWasm's existing duck-typed dispatch drives it unchanged.
class QuickjsBridge
  # A handle to a live JS value in the quickjs VM. Implements the same bridge
  # ABI Dommy objects do, so MrubyWasm's `v.respond_to?(:__js_get__)` dispatch
  # treats a JS object exactly like a Dommy one.
  class JsRef
    attr_reader :jsvalue

    def initialize(bridge, jsvalue)
      @bridge = bridge
      @jsvalue = jsvalue
    end

    def __js_get__(key)
      @bridge.wrap_result(@bridge.wb.get(@jsvalue, key))
    end

    def __js_set__(key, value)
      @bridge.wb.set(@jsvalue, key, @bridge.unwrap_arg(value))
      value
    end

    def __js_call__(method, args)
      @bridge.wrap_result(@bridge.wb.call(@jsvalue, method, args.map { |a| @bridge.unwrap_arg(a) }))
    end

    def __js_new__(args)
      @bridge.wrap_result(@bridge.wb.construct(@jsvalue, args.map { |a| @bridge.unwrap_arg(a) }))
    end
  end

  JSValue = Dommy::Js::Quickjs::WasmBridge::JSValue

  attr_reader :wb

  # `invoke` is called when JS fires a guest callback: invoke.(callback_id,
  # ruby_args) -> the guest's return value (primitive | JsRef | nil). MrubyWasm
  # passes its `invoke_callback` here so JS callbacks route into js_invoke_proc.
  def initialize(invoke:)
    @window = Dommy.new_window
    @runtime = Dommy::Js::Quickjs::Runtime.new
    @runtime.install_window(@window)
    @runtime.install_browser_globals
    @runtime.define_host_object("document", @window.document)
    @wb = @runtime.wasm_bridge
    @wb.on_invoke do |callback_id, packed_args|
      ruby_args = packed_args.map { |pa| wrap_result(@wb.unpack(pa)) }
      result = invoke.call(callback_id, ruby_args)
      @wb.pack(unwrap_arg(result))
    end
    @global = wrap_result(@wb.global_ref)
  end

  # Handle 1's value: quickjs globalThis.
  attr_reader :global

  # The Dommy window/document the runtime renders into. Exposed so host-side
  # tests (bundle/parity) can seed markup, query, and dispatch events on the
  # same DOM the wasm runtime sees, using Dommy's native Ruby API.
  attr_reader :window

  def document
    @window.document
  end

  # Evaluate real JS source (the JS.eval_javascript escape hatch).
  def eval(src)
    wrap_result(@wb.eval_js(src))
  end

  # A JS function that calls back into the guest's callback table by id.
  def make_callback(callback_id)
    wrap_result(@wb.make_callback(callback_id))
  end

  # Drive the event loop to quiescence: drain microtasks, advance Dommy's
  # deterministic scheduler to its next timer, repeat. Replaces MrubyWasm's
  # hand-rolled drain_async! with a real (WHATWG-ordered) event loop.
  def run_until_idle
    @runtime.run_until_idle
  end

  def on_log(&block)
    @runtime.on_log(&block)
  end

  def typeof(value)
    return @wb.typeof(value.jsvalue) if value.is_a?(JsRef)

    case value
    when nil               then "object" # typeof null === "object"
    when Integer, Float    then "number"
    when String            then "string"
    when true, false       then "boolean"
    else                        "object"
    end
  end

  def to_string(value)
    return @wb.to_string(value.jsvalue) if value.is_a?(JsRef)

    value.to_s
  end

  def strict_equal(a, b)
    return @wb.strict_equal(a.jsvalue, b.jsvalue) if a.is_a?(JsRef) && b.is_a?(JsRef)

    a == b
  end

  # JS null / undefined both unwrap to Ruby nil; a JsRef is never null.
  def null?(value)
    value.nil?
  end

  def instanceof(value, ctor)
    return false unless value.is_a?(JsRef) && ctor.is_a?(JsRef)

    @wb.instance_of?(value.jsvalue, ctor.jsvalue)
  end

  # WasmBridge value (primitive | JSValue) -> handle value (primitive | JsRef).
  def wrap_result(value)
    value.is_a?(JSValue) ? JsRef.new(self, value) : value
  end

  # Handle value (primitive | JsRef | Array | Hash) -> WasmBridge arg, turning
  # JsRefs back into their underlying JSValues (recursively for collections).
  def unwrap_arg(value)
    case value
    when JsRef then value.jsvalue
    when Array then value.map { |e| unwrap_arg(e) }
    when Hash  then value.transform_values { |e| unwrap_arg(e) }
    else value
    end
  end
end
