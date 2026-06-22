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
#   make pages-pack        Stage gh-pages CDN tree under dist-pages/v$VERSION/
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
LIBMRUBY_LILAC_COMPILED         := $(MRUBY_DIR)/build/lilac-compiled/lib/libmruby.a
LIBMRUBY_LILAC_COMPILED_RELEASE := $(MRUBY_DIR)/build/lilac-compiled-release/lib/libmruby.a
LIBMRUBY_MRBC_HOST              := $(MRUBY_DIR)/build/mrbc-host/lib/libmruby.a
LIBMRUBY_MRBC_HOST_RELEASE      := $(MRUBY_DIR)/build/mrbc-host-release/lib/libmruby.a

BUILD_DIR := $(CURDIR)/build
BUILD_WASM_LILAC_FULL             := $(BUILD_DIR)/lilac-full.wasm
BUILD_WASM_LILAC_FULL_RELEASE     := $(BUILD_DIR)/lilac-full.release.wasm
BUILD_WASM_LILAC_COMPILED         := $(BUILD_DIR)/lilac-compiled.wasm
BUILD_WASM_LILAC_COMPILED_RELEASE := $(BUILD_DIR)/lilac-compiled.release.wasm
BUILD_WASM_MRBC_HOST              := $(BUILD_DIR)/mrbc-host.wasm
BUILD_WASM_MRBC_HOST_RELEASE      := $(BUILD_DIR)/mrbc-host.release.wasm

.PHONY: all \
        lilac-full lilac-full-release \
        lilac-compiled lilac-compiled-release \
        mrbc-host mrbc-host-release \
        lilac-all lilac-all-release \
        check-pair-diff \
        test test-node test-wasm test-bundle test-parity test-wasm-rb test-cli test-all \
        node-deps clean

all: lilac-full

# ── libmruby.a builds (one per build_config × release) ──────────────────
$(LIBMRUBY_LILAC_FULL):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

$(LIBMRUBY_LILAC_FULL_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

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
PAIR_BASES := value grammar class_parser collision_rules

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

# Default test: Ruby-only wasm spec runner (wasmtime-rb + Dommy).
# `make test-node` runs the same scenarios under Node + happy-dom.
test: test-wasm-rb

# Ruby-host wasm spec runner (no Node). Drives lilac-full.wasm via
# wasmtime-rb; the JS bridge runs real JS through dommy-js-quickjs
# (builds a native `quickjs` ext — needs a C toolchain). Set
# LILAC_JS_ENGINE=dommy-stub for the lower-fidelity stub evaluator.
test-wasm-rb: lilac-full
	cd cli && MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  bundle exec ruby -Itest -Ilib ../test/ruby_spec/spec_runner.rb

# Node + happy-dom runner — same scenarios under V8 (catches V8-only
# GC / closure bugs). Slower; CI / pre-release, not the inner loop.
test-node: test-wasm test-bundle test-parity

test-wasm: check-pair-diff lilac-full node_modules
	MRUBY_WASM_PATH=$(BUILD_WASM_LILAC_FULL) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  node --experimental-wasm-exnref test/runner.mjs

# :bundle delivery (ADR-0030) boot-time behavior — fetch the
# `<link rel="lilac-bundle">`, inject its <template>s, then mount. Needs
# both wasm targets (full evals the bundle's Ruby; compiled chains .mrb).
test-bundle: lilac-full lilac-compiled node_modules
	LILAC_FULL_WASM=$(BUILD_WASM_LILAC_FULL) \
	LILAC_COMPILED_WASM=$(BUILD_WASM_LILAC_COMPILED) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  node --experimental-wasm-exnref test/bundle-runtime.mjs

# :full vs :compiled DOM parity — build each fixture both ways, drive the
# same scenario, assert byte-identical DOM after every step. Guards the
# "same .lil → same DOM regardless of target" contract.
test-parity: lilac-full lilac-compiled node_modules
	LILAC_FULL_WASM=$(BUILD_WASM_LILAC_FULL) \
	LILAC_COMPILED_WASM=$(BUILD_WASM_LILAC_COMPILED) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  node --experimental-wasm-exnref test/parity-runner.mjs

# Ruby ports of test-bundle / test-parity (no Node). Build both wasm
# targets, so they're out of the default loop — run here and in test-all.
test-bundle-rb: lilac-full lilac-compiled
	cd cli && LILAC_FULL_WASM=$(BUILD_WASM_LILAC_FULL) \
	LILAC_COMPILED_WASM=$(BUILD_WASM_LILAC_COMPILED) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  bundle exec ruby -Itest test/test_bundle_runtime.rb

test-parity-rb: lilac-full lilac-compiled
	cd cli && LILAC_FULL_WASM=$(BUILD_WASM_LILAC_FULL) \
	LILAC_COMPILED_WASM=$(BUILD_WASM_LILAC_COMPILED) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  bundle exec ruby -Itest test/test_parity.rb

# CLI gem tests. The gem has its own Gemfile / Rakefile under cli/, so
# `cd cli` for bundle exec; this target wraps that.
test-cli:
	cd cli && bundle exec rake test

# Everything — slow (rebuilds wasm targets, runs both runners); pre-release / CI.
test-all: test-cli test-wasm-rb test-bundle-rb test-parity-rb test-node

# ── serve (examples in a browser) ──────────────────────────────────────
# Examples reference ../mrbgem/mruby-wasm-js/js/index.js from the
# mruby-wasm-runtime sibling. Copy it under lilac/mrbgem/ so the path
# resolves (wsv 403s on symlinks pointing outside the served root).
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


# ── GitHub Pages release staging ────────────────────────────────────────
# Stage a self-contained CDN tree under dist-pages/v$VERSION/ for the
# gh-pages branch (ADR-28): release wasm + boot helper (pages/lilac-full/)
# + the mruby-wasm-js bridge, all relative-imported (no bundler needed).
# Invoked by .github/workflows/release.yml on each v* tag.
PAGES_DIR     := $(CURDIR)/dist-pages
PAGES_SOURCE  := $(CURDIR)/pages/lilac-full
BRIDGE_SOURCE := $(MRUBY_WASM_RUNTIME)/mrbgem/mruby-wasm-js/js

# VERSION defaults to the current git tag; release workflow passes
# VERSION=v$tag explicitly. Local invocation: `make pages-pack VERSION=v0.1.0`.
VERSION ?= $(shell git describe --tags --exact-match 2>/dev/null || echo "vdev")

.PHONY: pages-pack
pages-pack: $(BUILD_WASM_LILAC_FULL_RELEASE)
	@mkdir -p $(PAGES_DIR)/$(VERSION)/mruby-wasm-js
	@cp $(BUILD_WASM_LILAC_FULL_RELEASE) $(PAGES_DIR)/$(VERSION)/lilac.wasm
	@cp $(PAGES_SOURCE)/index.js     $(PAGES_DIR)/$(VERSION)/index.js
	@cp $(PAGES_SOURCE)/index.d.ts   $(PAGES_DIR)/$(VERSION)/index.d.ts
	@cp $(PAGES_SOURCE)/README.md    $(PAGES_DIR)/$(VERSION)/README.md
	@cp $(PAGES_SOURCE)/LICENSE      $(PAGES_DIR)/$(VERSION)/LICENSE
	@cp $(BRIDGE_SOURCE)/*.js        $(PAGES_DIR)/$(VERSION)/mruby-wasm-js/
	@cp $(BRIDGE_SOURCE)/*.d.ts      $(PAGES_DIR)/$(VERSION)/mruby-wasm-js/ 2>/dev/null || true
	@echo "Pages tree staged at $(PAGES_DIR)/$(VERSION)/"
	@echo "Release workflow pushes this to gh-pages branch."

.PHONY: pages-clean
pages-clean:
	rm -rf $(PAGES_DIR)

# ── clean ───────────────────────────────────────────────────────────────
# `clean` removes everything Lilac generates: the wasm build dir, the
# mruby per-config build cache, and the pages-staged release tree.
clean: pages-clean
	rm -rf $(MRUBY_DIR)/build/lilac-*
	rm -rf $(MRUBY_DIR)/build/mrbc-host*
	rm -rf $(MRUBY_DIR)/build/lilac-full-host*
	rm -rf $(BUILD_DIR)
