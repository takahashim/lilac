# frozen_string_literal: true

# Build-time loader for `Lilac::Directives::*` files. The files under
# `directives/` are intentional duplicates of the runtime mrbgem at
# `runtime/mruby-lilac-directives/mrblib/` — they share class names so
# `diff(1)` between the pair surfaces only semantic differences. Per
# decisions §17, this means the individual files must NOT carry
# `require_relative` statements (the runtime mrbgem also has none —
# mruby-config drives load order there). MRI load order is owned here.

require_relative "cli/build/build_error" # lints.rb references Lilac::CLI::BuildError
require_relative "directives/value"
require_relative "directives/value_codegen" # build-time-only emit helpers (re-opens Value::Ivar / BareIdent)
require_relative "directives/grammar"
require_relative "directives/grammar_extra" # build-time-only predicates (class_name?, ref_ident?)
require_relative "directives/class_parser"
require_relative "directives/collision_rules" # COLLISION_PAIRS SSOT, consumed by lints.rb
require_relative "directives/lints"
