# npm packages

Two npm packages live here, both under the `@takahashim` scope. Each
is a self-contained install — boot helper + wasm bundle in one
package. Pick the variant for your use case:

| Directory | Package | Purpose |
|---|---|---|
| `lilac-full/`     | `@takahashim/lilac-full`     | full variant — runtime parser + directive scanner + every gem |
| `lilac-compiled/` | `@takahashim/lilac-compiled` | compiled variant — minimal runtime, requires `lilac-cli` to pre-compile |

The wasm files are **not checked into git** (see `.gitignore`); they
are produced from `build/*.release.wasm` by `make npm-pack`.

## Variants at a glance

| Variant | Size (raw / brotli) | Build step | Best for |
|---|---|---|---|
| `lilac-full`     | ~1.0 MB / ~322 KB | none | default, no-build, runtime canonical |
| `lilac-compiled` | ~530 KB / ~175 KB | `lilac build` (Ruby gem) | production size optimization |

## Release workflow

1. **Bump versions** in each `package.json`. The two packages share a
   single Lilac version line — bump them in lockstep.

2. **Build release wasms** + stage them under each variant dir:

   ```sh
   make lilac-full-release      # full release wasm
   make lilac-compiled-release  # compiled variant wasm
   make npm-pack                   # copies build/*.release.wasm → npm/lilac-*/lilac.wasm
   ```

3. **Dry-run** each package locally to inspect the tarball:

   ```sh
   cd npm/lilac-full     && npm pack --dry-run
   cd npm/lilac-compiled && npm pack --dry-run
   ```

4. **Publish** (requires an `npm login` with publish rights to the
   `@takahashim` scope):

   ```sh
   cd npm/lilac-full     && npm publish
   cd npm/lilac-compiled && npm publish
   ```

5. **Tag the git release** to match:

   ```sh
   git tag npm-v0.1.0
   git push origin npm-v0.1.0
   ```

## Local testing without publishing

Use `npm link` from the consumer side:

```sh
# In this repo
cd npm/lilac-full && npm link

# In a consumer project
npm link @takahashim/lilac-full
```

Then `import { boot } from "@takahashim/lilac-full"` resolves to your
working copy.
