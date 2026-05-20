/*
 * mruby-host-compile — exposes mruby's parser + codegen + bytecode
 * dumper as wasm exports so a Ruby host (lilac-cli, via wasmtime-rb)
 * can drive `lilac-full.wasm` in place of the standalone `mrbc`
 * binary.
 *
 * Three exports:
 *   compile_source(src_ptr, src_len, out_ptr_outp, out_len_outp,
 *                  err_ptr_outp, err_len_outp) -> i32 status
 *   mrbc_alloc(len) -> i32 ptr            (host writes source bytes here)
 *   mrbc_free(ptr)                         (host frees both input and output)
 *
 * The linker is asked to keep these symbols via
 * `-Wl,--export=compile_source` etc. in build_config/lilac-full.rb.
 * No `MRB_API` macros — these are plain extern symbols, the wasm
 * builder treats anything reachable from `--export` as live.
 *
 * mrb_state lifecycle: one `mrb_open()` + `mrb_close()` per call so
 * each compile is hermetic (matches `mrbc` binary's
 * process-per-invocation behavior). Symbol-table growth across many
 * calls would otherwise leak.
 *
 * Status codes — kept narrow so the host side maps them to a small
 * exception hierarchy:
 *   0  ok           — irep bytes in out_ptr / out_len
 *   1  compile fail — error message in err_ptr / err_len (utf-8)
 *   2  no compiler  — mruby was built without mruby-compiler. Should
 *                     never happen on lilac-full (the gem dep pins
 *                     mruby-compiler) but kept as a defensive check
 *                     so a future mis-config surfaces clearly.
 */

#include <stdint.h>
#include <stdio.h>   /* snprintf for error message formatting */
#include <stdlib.h>
#include <string.h>

#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/dump.h>
#include <mruby/irep.h>
#include <mruby/proc.h>
#include <mruby/internal.h>

/* ----- buffer helpers -------------------------------------------- */

/*
 * mrbgems' generated gem_init.c declares these symbols and the
 * mruby init path calls them when mrb_open() runs. We don't register
 * any Ruby-visible classes — `compile_source` is a wasm-export only,
 * not exposed back to mruby code — so both bodies are no-ops. They
 * exist purely to satisfy the linker (otherwise --allow-undefined
 * leaves them as imports and instantiation fails with "unknown
 * import").
 */
void
mrb_mruby_host_compile_gem_init(mrb_state *mrb)
{
  (void)mrb;
}

void
mrb_mruby_host_compile_gem_final(mrb_state *mrb)
{
  (void)mrb;
}

int32_t
mrbc_alloc(int32_t len)
{
  if (len < 0) return 0;
  void *p = malloc((size_t)len);
  return (int32_t)(uintptr_t)p;
}

void
mrbc_free(int32_t ptr)
{
  if (ptr == 0) return;
  free((void *)(uintptr_t)ptr);
}

/* ----- error serialization --------------------------------------- */

/*
 * Build a single utf-8 error message from the parser's error buffer
 * and write it into a freshly malloc'd buffer. Caller (host) frees
 * via mrbc_free. The host receives "line N: message" style output —
 * matches mrbc's stderr formatting closely enough that error parsing
 * doesn't need a separate codepath.
 */
static int32_t
write_parser_error(struct mrb_parser_state *p,
                   int32_t err_ptr_outp,
                   int32_t err_len_outp)
{
  if (!p || p->nerr == 0) return 0;

  /* Concatenate up to 4 errors so a syntax cascade doesn't drown the
   * host. Most user errors are a single message anyway. */
  size_t cap = 0;
  size_t to_emit = p->nerr < 4 ? p->nerr : 4;
  for (size_t i = 0; i < to_emit; i++) {
    cap += 64;  /* "line %d: " header upper bound */
    cap += p->error_buffer[i].message ? strlen(p->error_buffer[i].message) : 0;
    cap += 1;   /* '\n' */
  }
  cap += 1;     /* trailing NUL just for sanity, host reads via len */

  char *buf = (char *)malloc(cap);
  if (!buf) return 0;
  char *cursor = buf;
  size_t remaining = cap;
  for (size_t i = 0; i < to_emit; i++) {
    int n = snprintf(cursor, remaining, "line %d: %s\n",
                     p->error_buffer[i].lineno,
                     p->error_buffer[i].message ? p->error_buffer[i].message : "(no message)");
    if (n < 0 || (size_t)n >= remaining) break;
    cursor += n;
    remaining -= (size_t)n;
  }
  size_t used = (size_t)(cursor - buf);

  *(int32_t *)(uintptr_t)err_ptr_outp = (int32_t)(uintptr_t)buf;
  *(int32_t *)(uintptr_t)err_len_outp = (int32_t)used;
  return 1;
}

/*
 * Fallback error reporter when we have a string but no parser_state
 * (e.g. mrb_generate_code returned NULL). Writes a single line.
 */
static void
write_static_error(const char *msg,
                   int32_t err_ptr_outp,
                   int32_t err_len_outp)
{
  size_t len = strlen(msg);
  char *buf = (char *)malloc(len);
  if (!buf) {
    *(int32_t *)(uintptr_t)err_ptr_outp = 0;
    *(int32_t *)(uintptr_t)err_len_outp = 0;
    return;
  }
  memcpy(buf, msg, len);
  *(int32_t *)(uintptr_t)err_ptr_outp = (int32_t)(uintptr_t)buf;
  *(int32_t *)(uintptr_t)err_len_outp = (int32_t)len;
}

/* ----- compile entry point --------------------------------------- */

int32_t
compile_source(int32_t src_ptr,
               int32_t src_len,
               int32_t out_ptr_outp,
               int32_t out_len_outp,
               int32_t err_ptr_outp,
               int32_t err_len_outp)
{
  /* Defensive: clear outparams up front so the host always sees a
   * well-defined value even on early returns. */
  *(int32_t *)(uintptr_t)out_ptr_outp = 0;
  *(int32_t *)(uintptr_t)out_len_outp = 0;
  *(int32_t *)(uintptr_t)err_ptr_outp = 0;
  *(int32_t *)(uintptr_t)err_len_outp = 0;

  if (src_ptr == 0 || src_len < 0) {
    write_static_error("compile_source: invalid src buffer", err_ptr_outp, err_len_outp);
    return 1;
  }

  mrb_state *mrb = mrb_open();
  if (!mrb) {
    write_static_error("compile_source: mrb_open failed", err_ptr_outp, err_len_outp);
    return 1;
  }

  mrb_ccontext *cxt = mrbc_context_new(mrb);
  if (!cxt) {
    mrb_close(mrb);
    write_static_error("compile_source: mrbc_context_new failed", err_ptr_outp, err_len_outp);
    return 1;
  }
  mrbc_filename(mrb, cxt, "(lilac-cli)");

  const char *src = (const char *)(uintptr_t)src_ptr;
  struct mrb_parser_state *p = mrb_parse_nstring(mrb, src, (size_t)src_len, cxt);
  if (!p) {
    mrbc_context_free(mrb, cxt);
    mrb_close(mrb);
    write_static_error("compile_source: mrb_parse_nstring returned NULL", err_ptr_outp, err_len_outp);
    return 1;
  }
  if (p->nerr > 0) {
    write_parser_error(p, err_ptr_outp, err_len_outp);
    mrb_parser_free(p);
    mrbc_context_free(mrb, cxt);
    mrb_close(mrb);
    return 1;
  }

  struct RProc *proc = mrb_generate_code(mrb, p);
  if (!proc) {
    mrb_parser_free(p);
    mrbc_context_free(mrb, cxt);
    mrb_close(mrb);
    write_static_error("compile_source: mrb_generate_code returned NULL", err_ptr_outp, err_len_outp);
    return 1;
  }

  uint8_t *bin = NULL;
  size_t binsize = 0;
  /* flags = 0: no debug info, no static, no lvar omission — matches
   * the default `mrbc <file>` invocation. If we ever need debug
   * tables (line numbers in stack traces) flip MRB_DUMP_DEBUG_INFO
   * on. */
  int rc = mrb_dump_irep(mrb, proc->body.irep, 0, &bin, &binsize);
  if (rc != MRB_DUMP_OK || !bin || binsize == 0) {
    mrb_parser_free(p);
    mrbc_context_free(mrb, cxt);
    mrb_close(mrb);
    write_static_error("compile_source: mrb_dump_irep failed", err_ptr_outp, err_len_outp);
    return 1;
  }

  /* Copy into a malloc'd buffer so the host frees through `mrbc_free`
   * symmetrically (mrb_dump_irep's buffer lives in mruby's allocator,
   * which gets torn down by `mrb_close` — we'd be left with a
   * dangling pointer if we tried to hand it out raw). */
  void *out = malloc(binsize);
  if (!out) {
    mrb_free(mrb, bin);
    mrb_parser_free(p);
    mrbc_context_free(mrb, cxt);
    mrb_close(mrb);
    write_static_error("compile_source: out-of-memory copying bytecode", err_ptr_outp, err_len_outp);
    return 1;
  }
  memcpy(out, bin, binsize);
  mrb_free(mrb, bin);

  *(int32_t *)(uintptr_t)out_ptr_outp = (int32_t)(uintptr_t)out;
  *(int32_t *)(uintptr_t)out_len_outp = (int32_t)binsize;

  mrb_parser_free(p);
  mrbc_context_free(mrb, cxt);
  mrb_close(mrb);
  return 0;
}
