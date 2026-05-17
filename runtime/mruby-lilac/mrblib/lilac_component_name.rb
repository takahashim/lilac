# Mapping between `data-component` attribute strings and Ruby constants.
#
# Naming rule (PascalCase canonical; kebab-case も後方互換で受理。
# `--` は namespace separator):
#   "Counter"          → Counter        (canonical)
#   "counter"          → Counter        (legacy kebab, auto-camelized)
#   "UserProfile"      → UserProfile    (canonical)
#   "user-profile"     → UserProfile    (legacy kebab)
#   "Admin--UserCard"  → Admin::UserCard
#   "admin--user-card" → Admin::UserCard
#
# 新規コードは PascalCase を使う(Ruby class 名と HTML attribute 値が
# 1 対 1 で対応、grep / refactor しやすい)。kebab は既存 HTML との互換
# のために受理を維持する。
#
# Empty segments (`--foo`, `foo--`, `foo----bar`) raise Lilac::Error.
# Syntactically invalid constant names (e.g. starting
# with a digit) yield `nil` from `find_const` so callers can fall
# through to a warn+skip path instead of leaking NameError.
#
# Knows nothing about Lilac::Component — the subclass check belongs to
# the caller (Registry) so this module stays free of upward coupling.
module Lilac
  module ComponentName
    class << self
      def find_class(name)
        find_const(to_const_path(name))
      end

      def to_const_path(name)
        segments = name.split("--", -1)
        segments.each do |s|
          raise Error, "Invalid data-component name #{name.inspect}: empty namespace segment" if s.empty?
        end
        parts = segments.map { |seg| camelize_segment(seg) }
        raise Error, "Invalid data-component name #{name.inspect}: empty word segment" if parts.include?(nil)
        parts.join("::")
      end

      # mruby's const_get may not parse "A::B" strings reliably, so walk
      # the chain manually. NameError (raised by const_defined? on a
      # syntactically invalid identifier like "123Thing") is treated as
      # "not found" so malformed data-component names don't blow up.
      def find_const(path)
        begin
          path.split("::").inject(Object) do |scope, name|
            return nil unless scope.const_defined?(name)
            scope.const_get(name)
          end
        rescue NameError
          nil
        end
      end

      private

      # Returns the CamelCased form of one `--`-separated chunk, or nil
      # if the chunk contains an empty word (e.g., "foo-", "-bar"). The
      # caller composes the user-facing error because only it knows the
      # full data-component name.
      def camelize_segment(seg)
        seg.split("-").map { |word|
          return nil if word.empty?
          word[0].upcase + (word[1..] || "")
        }.join
      end
    end
  end
end
