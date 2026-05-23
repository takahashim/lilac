# lilac — build orchestration for the Lilac wasm bundles.
#
# Reuses the mruby clone and wasi-sdk installed by mruby-wasm-runtime:
# point MRUBY_WASM_RUNTIME_PATH at a local clone of that repo and this
# Makefile picks up `mruby/` and `vendor/wasi-sdk/` from there.
#
# Targets:
#   make lilac-full        Build → build/lilac-full.wasm
#   make lilac-compiled    Build → build/lilac-compiled.wasm
#   make lilac-all         Build both variants (dev)
#   make lilac-all-release Build both variants (release: -Oz + strip-debug;
#                          compile-time -flto handled by build_config)
#   make test              Run wasm_spec against the full bundle
#   make npm-pack          Stage release wasms into npm/lilac-*/lilac.wasm
#   make clean             Remove this repo's build/ artifacts

# Locate mruby-wasm-runtime. ENV takes precedence; otherwise look at
# the sibling directory (../mruby-wasm-runtime).
MRUBY_WASM_RUNTIME ?= $(realpath $(CURDIR)/../mruby-wasm-runtime)
ifeq ($(MRUBY_WASM_RUNTIME),)
  $(error MRUBY_WASM_RUNTIME_PATH not set and no sibling ../mruby-wasm-runtime found. \
          Set MRUBY_WASM_RUNTIME_PATH or clone mruby-wasm-runtime alongside this repo.)
endif
ifeq ($(wildcard $(MRUBY_WASM_RUNTIME)/mrbgem/mruby-wasm-js),)
  $(error MRUBY_WASM_RUNTIME=$(MRUBY_WASM_RUNTIME) does not look like a mruby-wasm-runtime clone)
endif
export MRUBY_WASM_RUNTIME_PATH := $(MRUBY_WASM_RUNTIME)

# Reuse mruby clone + wasi-sdk from mruby-wasm-runtime so we don't
# re-download / re-clone gigabytes per workspace.
MRUBY_DIR    := $(MRUBY_WASM_RUNTIME)/mruby
WASI_SDK_DIR := $(MRUBY_WASM_RUNTIME)/vendor/wasi-sdk
ifeq ($(wildcard $(WASI_SDK_DIR)/bin/clang),)
  ifndef WASI_SDK_PATH
    $(error wasi-sdk not found at $(WASI_SDK_DIR). \
            Run `make wasi-sdk` in mruby-wasm-runtime, or set WASI_SDK_PATH.)
  endif
else
  export WASI_SDK_PATH := $(WASI_SDK_DIR)
endif
CLANG   := $(WASI_SDK_DIR)/bin/clang
SYSROOT := $(WASI_SDK_DIR)/share/wasi-sysroot
TARGET  := wasm32-wasip1

JS_WASM_RELEASE_LDFLAGS := -Wl,--strip-debug

MRUBY_CONFIG_LILAC_FULL     := $(CURDIR)/build_config/lilac-full.rb
MRUBY_CONFIG_LILAC_COMPILED := $(CURDIR)/build_config/lilac-compiled.rb
MRUBY_CONFIG_MRBC_HOST      := $(CURDIR)/build_config/mrbc-host.rb

LIBMRUBY_LILAC_FULL             := $(MRUBY_DIR)/build/lilac-full/lib/libmruby.a
LIBMRUBY_LILAC_FULL_RELEASE     := $(MRUBY_DIR)/build/lilac-full-release/lib/libmruby.a
LIBMRUBY_LILAC_FULL_HOST        := $(MRUBY_DIR)/build/lilac-full-host/lib/libmruby.a
LIBMRUBY_LILAC_COMPILED         := $(MRUBY_DIR)/build/lilac-compiled/lib/libmruby.a
LIBMRUBY_LILAC_COMPILED_RELEASE := $(MRUBY_DIR)/build/lilac-compiled-release/lib/libmruby.a
LIBMRUBY_MRBC_HOST              := $(MRUBY_DIR)/build/mrbc-host/lib/libmruby.a
LIBMRUBY_MRBC_HOST_RELEASE      := $(MRUBY_DIR)/build/mrbc-host-release/lib/libmruby.a

BUILD_DIR := $(CURDIR)/build
BUILD_WASM_LILAC_FULL             := $(BUILD_DIR)/lilac-full.wasm
BUILD_WASM_LILAC_FULL_RELEASE     := $(BUILD_DIR)/lilac-full.release.wasm
BUILD_WASM_LILAC_FULL_HOST        := $(BUILD_DIR)/lilac-full-host.wasm
BUILD_WASM_LILAC_COMPILED         := $(BUILD_DIR)/lilac-compiled.wasm
BUILD_WASM_LILAC_COMPILED_RELEASE := $(BUILD_DIR)/lilac-compiled.release.wasm
BUILD_WASM_MRBC_HOST              := $(BUILD_DIR)/mrbc-host.wasm
BUILD_WASM_MRBC_HOST_RELEASE      := $(BUILD_DIR)/mrbc-host.release.wasm

.PHONY: all \
        lilac-full lilac-full-release lilac-full-host \
        lilac-compiled lilac-compiled-release \
        lilac-plugin-extras \
        mrbc-host mrbc-host-release \
        lilac-all lilac-all-release \
        check-pair-diff \
        test test-node test-wasm test-wasm-rb test-cli test-all \
        node-deps clean

all: lilac-full

# ── libmruby.a builds (one per build_config × release) ──────────────────
$(LIBMRUBY_LILAC_FULL):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

$(LIBMRUBY_LILAC_FULL_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

$(LIBMRUBY_LILAC_FULL_HOST):
	cd $(MRUBY_DIR) && MRUBY_WASM_EH=new rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

$(LIBMRUBY_LILAC_COMPILED):
	cd $(MRUBY_DIR) && MRUBY_WASM_NO_COMPILER=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_COMPILED)

$(LIBMRUBY_LILAC_COMPILED_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_NO_COMPILER=1 MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_COMPILED)

$(LIBMRUBY_MRBC_HOST):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_MRBC_HOST)

$(LIBMRUBY_MRBC_HOST_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_MRBC_HOST)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ── JS-host wasm (link libmruby.a into a reactor module) ────────────────
# Args:
#   $(1) — opt-level (e.g. -Oz for release)
#   $(2) — release ldflags (e.g. --strip-debug)
#   $(3) — libmruby.a path
#   $(4) — output wasm path
#   $(5) — extra `-Wl,--export=…` flags (target-specific symbols beyond
#          the shared JS bridge trio)
define LINK_JS_WASM
$(CLANG) --target=$(TARGET) --sysroot=$(SYSROOT) \
  $(1) \
  -mexec-model=reactor \
  -Wl,--allow-undefined \
  $(2) \
  -Wl,--export=js_invoke_proc \
  -Wl,--export=js_eval_handle \
  -Wl,--export=js_load_irep_handle \
  $(5) \
  -Wl,--whole-archive $(3) -Wl,--no-whole-archive \
  -o $(4) \
  -lsetjmp
@echo "Built $(4) ($$(du -h $(4) | cut -f1))"
endef

# Extra wasm exports for the `lilac-full` variant only: the
# `mruby-host-compile` mrbgem (runtime/mruby-host-compile/) provides
# compile_source / mrbc_alloc / mrbc_free so the Ruby CLI can drive the
# wasm as an mrbc replacement via wasmtime-rb. Required by lilac-wasm-bin
# Phase 2 — the `lilac-compiled` variant doesn't include the gem (no
# mruby-compiler) so its link must NOT request these exports (would fail
# with "undefined symbol").
LILAC_FULL_EXTRA_EXPORTS := -Wl,--export=compile_source \
                            -Wl,--export=mrbc_alloc \
                            -Wl,--export=mrbc_free

lilac-full: $(BUILD_WASM_LILAC_FULL)
lilac-full-release: $(BUILD_WASM_LILAC_FULL_RELEASE)
lilac-full-host: $(BUILD_WASM_LILAC_FULL_HOST)
lilac-compiled: $(BUILD_WASM_LILAC_COMPILED)
lilac-compiled-release: $(BUILD_WASM_LILAC_COMPILED_RELEASE)
mrbc-host: $(BUILD_WASM_MRBC_HOST)
mrbc-host-release: $(BUILD_WASM_MRBC_HOST_RELEASE)
lilac-all: lilac-full lilac-compiled
lilac-all-release: lilac-full-release lilac-compiled-release

$(BUILD_WASM_LILAC_FULL): $(LIBMRUBY_LILAC_FULL) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_FULL),$(BUILD_WASM_LILAC_FULL),$(LILAC_FULL_EXTRA_EXPORTS))

$(BUILD_WASM_LILAC_FULL_RELEASE): $(LIBMRUBY_LILAC_FULL_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Oz,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_FULL_RELEASE),$(BUILD_WASM_LILAC_FULL_RELEASE),$(LILAC_FULL_EXTRA_EXPORTS))

$(BUILD_WASM_LILAC_FULL_HOST): $(LIBMRUBY_LILAC_FULL_HOST) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_FULL_HOST),$(BUILD_WASM_LILAC_FULL_HOST),$(LILAC_FULL_EXTRA_EXPORTS))

$(BUILD_WASM_LILAC_COMPILED): $(LIBMRUBY_LILAC_COMPILED) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_COMPILED),$(BUILD_WASM_LILAC_COMPILED),)

$(BUILD_WASM_LILAC_COMPILED_RELEASE): $(LIBMRUBY_LILAC_COMPILED_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Oz,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_COMPILED_RELEASE),$(BUILD_WASM_LILAC_COMPILED_RELEASE),)

# ── mrbc-host wasm (compiler-only reactor, no JS bridge) ────────────────
# Loaded by `lilac-cli`'s WasmMrbcDriver via wasmtime-rb. Only exports
# `compile_source` / `mrbc_alloc` / `mrbc_free` — no JS bridge symbols
# (the trio in LINK_JS_WASM) because nothing on the host side calls
# them and they'd pull in unused dead code.
#
# Args mirror LINK_JS_WASM but the export list is fixed.
define LINK_MRBC_HOST_WASM
$(CLANG) --target=$(TARGET) --sysroot=$(SYSROOT) \
  $(1) \
  -mexec-model=reactor \
  -Wl,--allow-undefined \
  $(2) \
  -Wl,--export=compile_source \
  -Wl,--export=mrbc_alloc \
  -Wl,--export=mrbc_free \
  -Wl,--whole-archive $(3) -Wl,--no-whole-archive \
  -o $(4) \
  -lsetjmp
@echo "Built $(4) ($$(du -h $(4) | cut -f1))"
endef

$(BUILD_WASM_MRBC_HOST): $(LIBMRUBY_MRBC_HOST) | $(BUILD_DIR)
	$(call LINK_MRBC_HOST_WASM,,,$(LIBMRUBY_MRBC_HOST),$(BUILD_WASM_MRBC_HOST))

$(BUILD_WASM_MRBC_HOST_RELEASE): $(LIBMRUBY_MRBC_HOST_RELEASE) | $(BUILD_DIR)
	$(call LINK_MRBC_HOST_WASM,-Oz,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_MRBC_HOST_RELEASE),$(BUILD_WASM_MRBC_HOST_RELEASE))

# ── duplicate-pair drift check ─────────────────────────────────────────
# Per decisions §17, the directive grammar layer is intentionally
# duplicated across `cli/lib/lilac/directives/` (build-time, MRI) and
# `runtime/mruby-lilac-directives/mrblib/` (runtime, mruby-on-wasm).
# The four bases below are byte-comparable pairs that MUST stay in
# sync; this target fails the test run if any pair drifts so a
# one-sided edit gets caught immediately rather than at the next time
# someone runs `diff(1)` by hand.
PAIR_BASES := value grammar class_parser compat_rules

check-pair-diff:
	@failed=0; \
	for base in $(PAIR_BASES); do \
	  cli_path="cli/lib/lilac/directives/$$base.rb"; \
	  rt_path="runtime/mruby-lilac-directives/mrblib/lilac_directives_$$base.rb"; \
	  if ! diff -q "$$cli_path" "$$rt_path" > /dev/null 2>&1; then \
	    echo "✗ diff-0 pair desync: $$cli_path ↔ $$rt_path"; \
	    diff -u "$$cli_path" "$$rt_path" || true; \
	    failed=1; \
	  else \
	    echo "✓ diff 0: $$base"; \
	  fi; \
	done; \
	exit $$failed

# ── test ────────────────────────────────────────────────────────────────
node_modules: package.json
	npm install --no-audit --no-fund --silent
	@touch node_modules

# Default `make test` is the **Ruby-only** wasm spec runner — fast,
# no Node install required, drives lilac-full-host.wasm through
# wasmtime-rb + Dommy. Covers the same wasm_spec/ scenarios as the
# Node-based path; the Node runner remains available as `make
# test-node` for cross-checking against happy-dom in CI / pre-release.
test: test-wasm-rb

# Ruby-side wasm spec runner — pure-Ruby host, no Node dependency.
# Drives lilac-full-host.wasm (new-EH variant) through wasmtime-rb.
test-wasm-rb: lilac-full-host
	cd cli && MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  bundle exec ruby -Itest -Ilib ../test/ruby_spec/spec_runner.rb

# Node + happy-dom runner — same scenarios as `test-wasm-rb` but with
# V8 as the wasm host and happy-dom as DOM. Used in CI to catch the
# rare classes of bugs that only surface under V8 (FinalizationRegistry
# timing, real JS callback closures, etc.). Slower than the Ruby
# runner; not needed for the inner dev loop.
test-node: test-wasm

# Legacy alias retained so older scripts / muscle memory keep working.
test-wasm: check-pair-diff lilac-full node_modules
	MRUBY_WASM_PATH=$(BUILD_WASM_LILAC_FULL) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  node test/runner.mjs

# Ruby-side CLI gem tests. The gem owns its own Gemfile / Rakefile
# under `cli/` (standard Ruby monorepo layout — see README), so the
# convention is to `cd cli` for any `bundle exec` work. This target
# wraps that so the root-level workflow doesn't have to.
test-cli:
	cd cli && bundle exec rake test

# Everything — CLI gem + Ruby wasm spec + Node wasm spec. Slow
# because `test-node` rebuilds lilac-full; use pre-release / in CI.
test-all: test-cli test-wasm-rb test-node

# ── serve (examples in a browser) ──────────────────────────────────────
# Examples reference `../mrbgem/mruby-wasm-js/js/index.js`, which lives
# in the mruby-wasm-runtime sibling repo — not in lilac itself. We copy
# the bridge into lilac/mrbgem/ so the path resolves under the served
# root. (A symlink would be cheaper but wsv refuses to follow symlinks
# pointing outside the served root, returning 403.)
mrbgem:
	@echo "Copying mrbgem from $(MRUBY_WASM_RUNTIME)/mrbgem"
	@cp -R $(MRUBY_WASM_RUNTIME)/mrbgem mrbgem

.PHONY: serve
serve: lilac-full mrbgem
	@command -v wsv >/dev/null 2>&1 || { \
	  echo "wsv not installed. Run: gem install wsv"; \
	  exit 1; \
	}
	@echo "Serving lilac/ at http://127.0.0.1:8000/"
	@echo "Examples (runtime-only): http://127.0.0.1:8000/examples/runtime-only/"
	@echo "Examples (7GUIs gallery): cd examples/7guis && bundle exec lilac dev"
	@wsv .

# ── npm package staging ─────────────────────────────────────────────────
# Copies *.release.wasm into npm/{lilac-full,lilac-compiled}/lilac.wasm
# so the variant packages can be `npm publish`'d from those directories.
# Uses *-release artefacts (= -Os + symbol stripping); dev wasms are ~5x
# larger and not suitable for end users.
NPM_DIR := $(CURDIR)/npm

.PHONY: npm-pack
npm-pack: $(NPM_DIR)/lilac-full/lilac.wasm \
          $(NPM_DIR)/lilac-compiled/lilac.wasm \
          $(NPM_DIR)/lilac-plugin-extras/extras.mrb
	@echo "npm packages staged. To publish:"
	@echo "  cd npm/lilac-full          && npm publish"
	@echo "  cd npm/lilac-compiled      && npm publish"
	@echo "  cd npm/lilac-plugin-extras && npm publish"

$(NPM_DIR)/lilac-full/lilac.wasm: $(BUILD_WASM_LILAC_FULL_RELEASE)
	cp $< $@

$(NPM_DIR)/lilac-compiled/lilac.wasm: $(BUILD_WASM_LILAC_COMPILED_RELEASE)
	cp $< $@

# Plug-in package: pre-compiled mruby bytecode for data-tooltip /
# data-autofocus directives. Driven by `lilac plugin-build`, which
# resolves an mrbc backend via the same chain `lilac build` uses
# (env override → monorepo mrbc → lilac-wasm-bin's mrbc-host.wasm
# → $PATH). The dev mrbc-host.wasm is listed as an order-only dep so
# the wasm fallback is available without forcing a rebuild on every
# plug-in touch — if you have a native mrbc in $PATH / via env, that
# path takes priority and the order-only dep is harmless.
EXTRAS_MRBLIB := $(CURDIR)/runtime/mruby-lilac-extras/mrblib
EXTRAS_RB_FILES := $(EXTRAS_MRBLIB)/lilac_extras.rb \
                   $(EXTRAS_MRBLIB)/lilac_extras_focus.rb \
                   $(EXTRAS_MRBLIB)/lilac_extras_tooltip.rb

.PHONY: lilac-plugin-extras
lilac-plugin-extras: $(NPM_DIR)/lilac-plugin-extras/extras.mrb

$(NPM_DIR)/lilac-plugin-extras/extras.mrb: $(EXTRAS_RB_FILES) | $(BUILD_WASM_MRBC_HOST)
	cd $(CURDIR)/cli && bundle exec exe/lilac plugin-build $(EXTRAS_RB_FILES) -o $@

.PHONY: npm-clean
npm-clean:
	rm -f $(NPM_DIR)/lilac-full/lilac.wasm
	rm -f $(NPM_DIR)/lilac-compiled/lilac.wasm
	rm -f $(NPM_DIR)/lilac-plugin-extras/extras.mrb

# ── clean ───────────────────────────────────────────────────────────────
# `clean` removes everything Lilac generates: the wasm build dir, the
# mruby per-config build cache, and the npm-staged wasm artefacts.
# The latter used to be excluded, which let stale (e.g. LTO-era) wasm
# files survive a `make clean` and then trip up `CompiledRuntimeResolver`
# when it fell through to the npm fallback — keep this scoped wide so
# the obvious "wipe everything" workflow really does wipe everything.
# Use `make npm-clean` standalone when you only want to drop the npm
# wasm (during a release flow that's about to repack from build/).
clean: npm-clean
	rm -rf $(MRUBY_DIR)/build/lilac-*
	rm -rf $(MRUBY_DIR)/build/mrbc-host*
	rm -rf $(MRUBY_DIR)/build/lilac-full-host*
	rm -rf $(BUILD_DIR)
