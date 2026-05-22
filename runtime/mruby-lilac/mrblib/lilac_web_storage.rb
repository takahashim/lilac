# lilac_web_storage.rb — Thin wrapper over the WHATWG Web Storage API
# (`localStorage` / `sessionStorage`). Pairs a backend with a single
# key + JSON (de)serialization. Used by `Component#persistent_signal`
# / `Component#session_signal` as the read/write target; also usable
# standalone for one-off storage writes outside the signal pattern.
#
# Why a dedicated class instead of inlining the read/write into each
# signal helper: the current matrix is two backends × five concerns
# (read, deserialize, default fallback, signal binding, write effect).
# Without an abstraction, every backend × concern combination has to
# live in its own method body. Centralizing the storage I/O here keeps
# `persistent_signal` / `session_signal` to a 3-line wrapper apiece,
# and gives future axes (debounce, cross-tab sync, migration) a single
# place to land.

module Lilac
  class WebStorage
    # JS property names of the two Web Storage backends. Symbols match
    # the actual `window[:localStorage]` / `window[:sessionStorage]`
    # property keys so `JS.global[@backend]` is a direct lookup.
    BACKENDS = %i[localStorage sessionStorage].freeze

    attr_reader :backend, :key

    def initialize(backend, key)
      unless BACKENDS.include?(backend)
        raise ArgumentError,
              "backend must be one of #{BACKENDS.inspect}, got #{backend.inspect}"
      end
      raise ArgumentError, "key must not be empty" if key.to_s.empty?

      @backend = backend
      @key = key.to_s
    end

    # Return the parsed stored value when present and JSON-parseable.
    # On miss (key absent, or backend unavailable) OR on JSON parse
    # failure, yield to the block and return its result. Parse errors
    # emit a warn-level log via `Lilac.logger`; absence is silent.
    def fetch(&fallback)
      raise ArgumentError, "block required" unless fallback

      with_backend(missing: fallback) do |js|
        raw = js.call(:getItem, @key)
        next fallback.call if raw.js_null?

        Lilac::JSON.parse(raw.to_s)
      end
    rescue JS::Error => e
      Lilac.logger.warn(
        "Lilac::WebStorage(#{@backend}:#{@key.inspect}): load failed " \
          "(#{e.class}: #{e.message}); using fallback"
      )
      fallback.call
    end

    # Serialize via `Lilac::JSON.generate` and store. Write errors
    # (quota exceeded etc.) bubble through as `JS::Error` so the
    # caller's effect boundary / error handler can react. No-op when
    # the backend is unavailable, matching `fetch` / `remove`.
    def write(value)
      with_backend do |js|
        js.call(:setItem, @key, Lilac::JSON.generate(value))
      end
      nil
    end

    # Remove this entry from the backing storage. No-op when the
    # backend is unavailable (e.g. headless environments without
    # the storage API).
    def remove
      with_backend do |js|
        js.call(:removeItem, @key)
      end
      nil
    end

    private

    # Yield the JS storage object when reachable; otherwise either
    # call `missing` (if given) or return nil. Keeps the headless-env
    # guard in one place so `fetch` / `write` / `remove` behave
    # consistently.
    def with_backend(missing: nil)
      js = JS.global[@backend]
      if js.js_null?
        return missing.call if missing

        return nil
      end
      yield js
    end
  end
end
