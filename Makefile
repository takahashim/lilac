# lilac — build orchestration for the Lilac wasm bundles.
#
# Reuses the mruby clone and wasi-sdk installed by mruby-wasm-runtime:
# point MRUBY_WASM_RUNTIME_PATH at a local clone of that repo and this
# Makefile picks up `mruby/` and `vendor/wasi-sdk/` from there.
#
# Targets:
#   make js-lilac-full     Build → build/mruby-js-lilac-full.wasm
#   make js-lilac-small    Build → build/mruby-js-lilac-small.wasm
#   make js-lilac-min      Build → build/mruby-js-lilac-min.wasm
#   make test                Run wasm_spec against the full bundle
#   make clean               Remove this repo's build/ artifacts

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

MRUBY_CONFIG_LILAC_FULL  := $(CURDIR)/build_config/wasi-js-lilac-full.rb
MRUBY_CONFIG_LILAC_SMALL := $(CURDIR)/build_config/wasi-js-lilac-small.rb
MRUBY_CONFIG_LILAC_MIN   := $(CURDIR)/build_config/wasi-js-lilac-min.rb

LIBMRUBY_LILAC_FULL          := $(MRUBY_DIR)/build/wasi-js-lilac-full/lib/libmruby.a
LIBMRUBY_LILAC_FULL_RELEASE  := $(MRUBY_DIR)/build/wasi-js-lilac-full-release/lib/libmruby.a
LIBMRUBY_LILAC_SMALL         := $(MRUBY_DIR)/build/wasi-js-lilac-small/lib/libmruby.a
LIBMRUBY_LILAC_SMALL_RELEASE := $(MRUBY_DIR)/build/wasi-js-lilac-small-release/lib/libmruby.a
LIBMRUBY_LILAC_MIN           := $(MRUBY_DIR)/build/wasi-js-lilac-min/lib/libmruby.a
LIBMRUBY_LILAC_MIN_RELEASE   := $(MRUBY_DIR)/build/wasi-js-lilac-min-release/lib/libmruby.a

BUILD_DIR := $(CURDIR)/build
BUILD_WASM_LILAC_FULL          := $(BUILD_DIR)/mruby-js-lilac-full.wasm
BUILD_WASM_LILAC_FULL_RELEASE  := $(BUILD_DIR)/mruby-js-lilac-full.release.wasm
BUILD_WASM_LILAC_SMALL         := $(BUILD_DIR)/mruby-js-lilac-small.wasm
BUILD_WASM_LILAC_SMALL_RELEASE := $(BUILD_DIR)/mruby-js-lilac-small.release.wasm
BUILD_WASM_LILAC_MIN           := $(BUILD_DIR)/mruby-js-lilac-min.wasm
BUILD_WASM_LILAC_MIN_RELEASE   := $(BUILD_DIR)/mruby-js-lilac-min.release.wasm

.PHONY: all \
        js-lilac-full js-lilac-full-release \
        js-lilac-small js-lilac-small-release \
        js-lilac-min js-lilac-min-release \
        js-all js-all-release \
        test node-deps clean

all: js-lilac-full

# ── libmruby.a builds (one per build_config × release) ──────────────────
$(LIBMRUBY_LILAC_FULL):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

$(LIBMRUBY_LILAC_FULL_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_FULL)

$(LIBMRUBY_LILAC_SMALL):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_SMALL)

$(LIBMRUBY_LILAC_SMALL_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_SMALL)

$(LIBMRUBY_LILAC_MIN):
	cd $(MRUBY_DIR) && MRUBY_WASM_NO_COMPILER=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_MIN)

$(LIBMRUBY_LILAC_MIN_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_NO_COMPILER=1 MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_LILAC_MIN)

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

js-lilac-full: $(BUILD_WASM_LILAC_FULL)
js-lilac-full-release: $(BUILD_WASM_LILAC_FULL_RELEASE)
js-lilac-small: $(BUILD_WASM_LILAC_SMALL)
js-lilac-small-release: $(BUILD_WASM_LILAC_SMALL_RELEASE)
js-lilac-min: $(BUILD_WASM_LILAC_MIN)
js-lilac-min-release: $(BUILD_WASM_LILAC_MIN_RELEASE)
js-all: js-lilac-full js-lilac-small js-lilac-min
js-all-release: js-lilac-full-release js-lilac-small-release js-lilac-min-release

$(BUILD_WASM_LILAC_FULL): $(LIBMRUBY_LILAC_FULL) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_FULL),$(BUILD_WASM_LILAC_FULL))

$(BUILD_WASM_LILAC_FULL_RELEASE): $(LIBMRUBY_LILAC_FULL_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Os,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_FULL_RELEASE),$(BUILD_WASM_LILAC_FULL_RELEASE))

$(BUILD_WASM_LILAC_SMALL): $(LIBMRUBY_LILAC_SMALL) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_SMALL),$(BUILD_WASM_LILAC_SMALL))

$(BUILD_WASM_LILAC_SMALL_RELEASE): $(LIBMRUBY_LILAC_SMALL_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Os,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_SMALL_RELEASE),$(BUILD_WASM_LILAC_SMALL_RELEASE))

$(BUILD_WASM_LILAC_MIN): $(LIBMRUBY_LILAC_MIN) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_LILAC_MIN),$(BUILD_WASM_LILAC_MIN))

$(BUILD_WASM_LILAC_MIN_RELEASE): $(LIBMRUBY_LILAC_MIN_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Os,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_LILAC_MIN_RELEASE),$(BUILD_WASM_LILAC_MIN_RELEASE))

# ── test ────────────────────────────────────────────────────────────────
node_modules: package.json
	npm install --no-audit --no-fund --silent
	@touch node_modules

test: js-lilac-full node_modules
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
serve: js-lilac-full mrbgem
	@command -v wsv >/dev/null 2>&1 || { \
	  echo "wsv not installed. Run: gem install wsv"; \
	  exit 1; \
	}
	@echo "Serving lilac/ at http://127.0.0.1:8000/"
	@echo "Examples: http://127.0.0.1:8000/examples/"
	@wsv .

# ── clean ───────────────────────────────────────────────────────────────
clean:
	rm -rf $(MRUBY_DIR)/build/wasi-js-lilac-*
	rm -rf $(BUILD_DIR)
