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

LIBMRUBY_LILAC_FULL             := $(MRUBY_DIR)/build/lilac-full/lib/libmruby.a
LIBMRUBY_LILAC_FULL_RELEASE     := $(MRUBY_DIR)/build/lilac-full-release/lib/libmruby.a
LIBMRUBY_LILAC_COMPILED         := $(MRUBY_DIR)/build/lilac-compiled/lib/libmruby.a
LIBMRUBY_LILAC_COMPILED_RELEASE := $(MRUBY_DIR)/build/lilac-compiled-release/lib/libmruby.a

BUILD_DIR := $(CURDIR)/build
BUILD_WASM_LILAC_FULL             := $(BUILD_DIR)/lilac-full.wasm
BUILD_WASM_LILAC_FULL_RELEASE     := $(BUILD_DIR)/lilac-full.release.wasm
BUILD_WASM_LILAC_COMPILED         := $(BUILD_DIR)/lilac-compiled.wasm
BUILD_WASM_LILAC_COMPILED_RELEASE := $(BUILD_DIR)/lilac-compiled.release.wasm

.PHONY: all \
        lilac-full lilac-full-release \
        lilac-compiled lilac-compiled-release \
        lilac-all lilac-all-release \
        test node-deps clean

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

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ── JS-host wasm (link libmruby.a into a reactor module) ────────────────
define LINK_JS_WASM
$(CLANG) --target=$(TARGET) --sysroot=$(SYSROOT) \
  $(1) \
  -mexec-model=reactor \
  -Wl,--allow-undefined \
  $(2) \
  -Wl,--export=js_invoke_proc \
  -Wl,--export=js_eval_handle \
  -Wl,--export=js_load_irep_handle \
  -Wl,--whole-archive $(3) -Wl,--no-whole-archive \
  -o $(4) \
  -lsetjmp
@echo "Built $(4) ($$(du -h $(4) | cut -f1))"
endef

lilac-full: $(BUILD_WASM_LILAC_FULL)
lilac-full-release: $(BUILD_WASM_LILAC_FULL_RELEASE)
lilac-compiled: $(BUILD_WASM_LILAC_COMPILED)
lilac-compiled-release: $(BUILD_WASM_LILAC_COMPILED_RELEASE)
lilac-all: lilac-full lilac-compiled
lilac-all-release: lilac-full-release lilac-compiled-release

$(BUILD_WASM_LILAC_FULL): $(LIBMRUBY_LILAC_FULL) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_FULL),$(BUILD_WASM_LILAC_FULL))

$(BUILD_WASM_LILAC_FULL_RELEASE): $(LIBMRUBY_LILAC_FULL_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Oz,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_FULL_RELEASE),$(BUILD_WASM_LILAC_FULL_RELEASE))

$(BUILD_WASM_LILAC_COMPILED): $(LIBMRUBY_LILAC_COMPILED) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_COMPILED),$(BUILD_WASM_LILAC_COMPILED))

$(BUILD_WASM_LILAC_COMPILED_RELEASE): $(LIBMRUBY_LILAC_COMPILED_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Oz,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_COMPILED_RELEASE),$(BUILD_WASM_LILAC_COMPILED_RELEASE))

# ── test ────────────────────────────────────────────────────────────────
node_modules: package.json
	npm install --no-audit --no-fund --silent
	@touch node_modules

test: lilac-full node_modules
	MRUBY_WASM_PATH=$(BUILD_WASM_LILAC_FULL) \
	MRUBY_WASM_RUNTIME_PATH=$(MRUBY_WASM_RUNTIME) \
	  node test/runner.mjs

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
	@echo "Examples: http://127.0.0.1:8000/examples/"
	@wsv .

# ── npm package staging ─────────────────────────────────────────────────
# Copies *.release.wasm into npm/{lilac-full,lilac-compiled}/lilac.wasm
# so the variant packages can be `npm publish`'d from those directories.
# Uses *-release artefacts (= -Os + symbol stripping); dev wasms are ~5x
# larger and not suitable for end users.
NPM_DIR := $(CURDIR)/npm

.PHONY: npm-pack
npm-pack: $(NPM_DIR)/lilac-full/lilac.wasm $(NPM_DIR)/lilac-compiled/lilac.wasm
	@echo "npm packages staged. To publish:"
	@echo "  cd npm/lilac-full     && npm publish"
	@echo "  cd npm/lilac-compiled && npm publish"

$(NPM_DIR)/lilac-full/lilac.wasm: $(BUILD_WASM_LILAC_FULL_RELEASE)
	cp $< $@

$(NPM_DIR)/lilac-compiled/lilac.wasm: $(BUILD_WASM_LILAC_COMPILED_RELEASE)
	cp $< $@

.PHONY: npm-clean
npm-clean:
	rm -f $(NPM_DIR)/lilac-full/lilac.wasm
	rm -f $(NPM_DIR)/lilac-compiled/lilac.wasm

# ── clean ───────────────────────────────────────────────────────────────
clean:
	rm -rf $(MRUBY_DIR)/build/lilac-*
	rm -rf $(BUILD_DIR)
