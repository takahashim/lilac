# grainet — build orchestration for the Grainet wasm bundles.
#
# Reuses the mruby clone and wasi-sdk installed by mruby-wasm-runtime:
# point MRUBY_WASM_RUNTIME_PATH at a local clone of that repo and this
# Makefile picks up `mruby/` and `vendor/wasi-sdk/` from there.
#
# Targets:
#   make js-grainet-full     Build → build/mruby-js-grainet-full.wasm
#   make js-grainet-small    Build → build/mruby-js-grainet-small.wasm
#   make js-grainet-min      Build → build/mruby-js-grainet-min.wasm
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

MRUBY_CONFIG_GRAINET_FULL  := $(CURDIR)/build_config/wasi-js-grainet-full.rb
MRUBY_CONFIG_GRAINET_SMALL := $(CURDIR)/build_config/wasi-js-grainet-small.rb
MRUBY_CONFIG_GRAINET_MIN   := $(CURDIR)/build_config/wasi-js-grainet-min.rb

LIBMRUBY_GRAINET_FULL          := $(MRUBY_DIR)/build/wasi-js-grainet-full/lib/libmruby.a
LIBMRUBY_GRAINET_FULL_RELEASE  := $(MRUBY_DIR)/build/wasi-js-grainet-full-release/lib/libmruby.a
LIBMRUBY_GRAINET_SMALL         := $(MRUBY_DIR)/build/wasi-js-grainet-small/lib/libmruby.a
LIBMRUBY_GRAINET_SMALL_RELEASE := $(MRUBY_DIR)/build/wasi-js-grainet-small-release/lib/libmruby.a
LIBMRUBY_GRAINET_MIN           := $(MRUBY_DIR)/build/wasi-js-grainet-min/lib/libmruby.a
LIBMRUBY_GRAINET_MIN_RELEASE   := $(MRUBY_DIR)/build/wasi-js-grainet-min-release/lib/libmruby.a

BUILD_DIR := $(CURDIR)/build
BUILD_WASM_GRAINET_FULL          := $(BUILD_DIR)/mruby-js-grainet-full.wasm
BUILD_WASM_GRAINET_FULL_RELEASE  := $(BUILD_DIR)/mruby-js-grainet-full.release.wasm
BUILD_WASM_GRAINET_SMALL         := $(BUILD_DIR)/mruby-js-grainet-small.wasm
BUILD_WASM_GRAINET_SMALL_RELEASE := $(BUILD_DIR)/mruby-js-grainet-small.release.wasm
BUILD_WASM_GRAINET_MIN           := $(BUILD_DIR)/mruby-js-grainet-min.wasm
BUILD_WASM_GRAINET_MIN_RELEASE   := $(BUILD_DIR)/mruby-js-grainet-min.release.wasm

.PHONY: all \
        js-grainet-full js-grainet-full-release \
        js-grainet-small js-grainet-small-release \
        js-grainet-min js-grainet-min-release \
        js-all js-all-release \
        test node-deps clean

all: js-grainet-full

# ── libmruby.a builds (one per build_config × release) ──────────────────
$(LIBMRUBY_GRAINET_FULL):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_GRAINET_FULL)

$(LIBMRUBY_GRAINET_FULL_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_GRAINET_FULL)

$(LIBMRUBY_GRAINET_SMALL):
	cd $(MRUBY_DIR) && rake MRUBY_CONFIG=$(MRUBY_CONFIG_GRAINET_SMALL)

$(LIBMRUBY_GRAINET_SMALL_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_GRAINET_SMALL)

$(LIBMRUBY_GRAINET_MIN):
	cd $(MRUBY_DIR) && MRUBY_WASM_NO_COMPILER=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_GRAINET_MIN)

$(LIBMRUBY_GRAINET_MIN_RELEASE):
	cd $(MRUBY_DIR) && MRUBY_WASM_NO_COMPILER=1 MRUBY_WASM_RELEASE=1 rake MRUBY_CONFIG=$(MRUBY_CONFIG_GRAINET_MIN)

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

js-grainet-full: $(BUILD_WASM_GRAINET_FULL)
js-grainet-full-release: $(BUILD_WASM_GRAINET_FULL_RELEASE)
js-grainet-small: $(BUILD_WASM_GRAINET_SMALL)
js-grainet-small-release: $(BUILD_WASM_GRAINET_SMALL_RELEASE)
js-grainet-min: $(BUILD_WASM_GRAINET_MIN)
js-grainet-min-release: $(BUILD_WASM_GRAINET_MIN_RELEASE)
js-all: js-grainet-full js-grainet-small js-grainet-min
js-all-release: js-grainet-full-release js-grainet-small-release js-grainet-min-release

$(BUILD_WASM_GRAINET_FULL): $(LIBMRUBY_GRAINET_FULL) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_GRAINET_FULL),$(BUILD_WASM_GRAINET_FULL))

$(BUILD_WASM_GRAINET_FULL_RELEASE): $(LIBMRUBY_GRAINET_FULL_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Os,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_GRAINET_FULL_RELEASE),$(BUILD_WASM_GRAINET_FULL_RELEASE))

$(BUILD_WASM_GRAINET_SMALL): $(LIBMRUBY_GRAINET_SMALL) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_GRAINET_SMALL),$(BUILD_WASM_GRAINET_SMALL))

$(BUILD_WASM_GRAINET_SMALL_RELEASE): $(LIBMRUBY_GRAINET_SMALL_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Os,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_GRAINET_SMALL_RELEASE),$(BUILD_WASM_GRAINET_SMALL_RELEASE))

$(BUILD_WASM_GRAINET_MIN): $(LIBMRUBY_GRAINET_MIN) | $(BUILD_DIR)
	$(call LINK_JS_WASM,,,$(LIBMRUBY_GRAINET_MIN),$(BUILD_WASM_GRAINET_MIN))

$(BUILD_WASM_GRAINET_MIN_RELEASE): $(LIBMRUBY_GRAINET_MIN_RELEASE) | $(BUILD_DIR)
	$(call LINK_JS_WASM,-Os,$(JS_WASM_RELEASE_LDFLAGS),$(LIBMRUBY_GRAINET_MIN_RELEASE),$(BUILD_WASM_GRAINET_MIN_RELEASE))

# ── test ────────────────────────────────────────────────────────────────
node_modules: package.json
	npm install --no-audit --no-fund --silent
	@touch node_modules

test: js-grainet-full node_modules
	MRUBY_WASM_PATH=$(BUILD_WASM_GRAINET_FULL) \
	  node $(MRUBY_WASM_RUNTIME)/mrbgem/mruby-wasm-js/wasm_spec/runner.mjs

# ── clean ───────────────────────────────────────────────────────────────
clean:
	rm -rf $(MRUBY_DIR)/build/wasi-js-grainet-*
	rm -rf $(BUILD_DIR)
