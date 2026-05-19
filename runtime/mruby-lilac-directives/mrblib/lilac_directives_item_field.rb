module Lilac
  module Directives
    # Backward-compatible alias of `Lilac::ItemField` (which now lives
    # in `mruby-lilac` core). The directives gem used to own the
    # implementation; moving it core-side lets the CLI codegen emit
    # `Lilac::ItemField.read(...)` calls that work in builds without
    # the runtime scanner (`lilac-compiled`).
    ItemField = ::Lilac::ItemField
  end
end
