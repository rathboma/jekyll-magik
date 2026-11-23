# jekyll-magik: Development Guide

A Jekyll plugin that replaces the image side of jekyll-assets (sprockets 4 +
mini_magick) with libvips, keeping the `{% asset %}` tag sites already use.
The README is the user-facing documentation. This file is for working on the
code.

## Status and the plan

#1 is implemented: the core, for files used as they are. Resizing (`magick:`)
raises "not supported" until #2 to #4. The plan is six GitHub issues; read the
one you're working on before starting:

| Issue | Part | Build order |
|---|---|---|
| #1 | Core: gem skeleton, source index, the tag for unresized files, the shared architecture | 1st |
| #5 | Benchmark and parity harness, README | 2nd, right after #1 |
| #2 | Global content-addressed cache, derivative identity and URLs | 3rd |
| #3 | libvips pipeline for the `magick:` args | 4th |
| #4 | Worker-process pool, the render barrier, fast writes | 5th |
| #6 | The beekeeper-studio/web migration (and a CI fix it can take today) | last |

Each part should land as its own PR, with `bench/run` numbers once #5 exists.

## The first user: beekeeper-studio/web

The scope, the targets and most of the tests come from the Beekeeper Studio
website (https://github.com/beekeeper-studio/web). Its own CLAUDE.md
explains the site; the parts that matter here are:

- `{% asset %}` usage: 364 tags in 134 files. Heaviest are
  `_includes/responsive-img.html` (srcsets), `_includes/lightbox-img.html`,
  `pages/blog.html` and `_layouts/archive.html` (thumbnails)
- `_plugins/seo-assets.rb`, `_plugins/image_size.rb` and
  `_plugins/stable_proxy_keys.rb`: what it does with `site.sprockets` today
- `workers/translate/src/assets.ts`: the digest regex and `stableKey` that
  asset URLs must satisfy (see "Rules")
- `.github/workflows/cloudflare.yml`: production is Cloudflare Workers, built
  and deployed from GitHub Actions

Baseline numbers (4 vCPU, production config, commit `0d39796`):

| Build | Time |
|---|---|
| Cold | 131s |
| CI, with the cache restored | 134s (jekyll-assets wipes its cache) |
| Local rebuild | 38.7s |
| Asset tags stubbed out (the floor) | 21.3s |

The cold build makes 2,180 resize calls for 591 unique derivatives, 90.8s
of ImageMagick. libvips does the same work in 33.7s on one core and 10.5s on
four. Targets: cold ≤ floor + 12s, warm ≤ floor + 3s.

## Architecture

```
{% asset %} ─► Args (parsed once) ─► Resolver ─► Source (sha512, dims via FastImage)
                                        │
                     no transform ──────┼──► original: sprockets-compatible URL
                     magick: args ──────┴──► Transform IR ─► keys ─► URL (returned now)
                                                                 │
                         Store (.jekyll-cache/magik) ── hit ─────┤
                                                                 │ miss
                         Pool: render thread writes the job into a worker's stdin
                         Worker processes load libvips, write objects into the Store
                                                                 │
                         :site :post_render barrier (drain results, raise failures)
                         AssetFile#write: hardlink objects, copy originals, into _site
```

Components (names from the issues; `lib/jekyll/magik/`):

- **`Config`**: reads `assets:` (`sources`, `destination`,
  `defaults.img.integrity`) and `magik:` (`cache_dir`, `workers`,
  `jpeg_quality`, `webp_quality`, `derivative_integrity`, `gc`, `manifest`)
- **`Resolver`**: builds the load paths in jekyll-assets' order, globs each
  once per build, and resolves names: exact, nested load path, extensionless
  with sprockets' tie-break. The logical path is relative to the first load
  path containing the file
- **`Source`**: filename, logical path, type, sha512 (lazy), dimensions (lazy,
  FastImage)
- **`Args`**: a parser compatible with `liquid-tag-parser` 2.0.2, run at Liquid
  parse time. Only values containing `{{` or `{%` are rendered per call
- **`Transform`**: the IR from the `magick:` front end. Canonical JSON of the
  user's arguments, plus `output_size(w, h)` (pure Ruby)
- **`Registry`**: per build, `dkey → Derivative`. Only the render thread
  touches it
- **`Store`**: objects, `index.json`, the source memo, the page → assets map,
  GC
- **`Pool`** and the worker script: spawned processes and a JSON-lines
  protocol over pipes
- **`AssetFile`** (`< Jekyll::StaticFile`): registered on first use, written
  at Jekyll's write phase
- **`Api`** (`site.magik`) and the filters `asset_url` and `asset_size`

## Rules (don't break these)

1. **Originals keep jekyll-assets' exact URLs.**
   `/assets/<logical path minus ext>-<sha512 hex of the file>.<ext>`. Verified
   for all 456 originals in beekeeper's sprockets manifest; a regression
   breaks every image URL search engines and caches hold.
2. **Every URL matches the digest grammar** beekeeper's translation Worker and
   IndexNow use: `/\/assets\/[\w./-]+?-(?:[0-9a-f]{64,128}|[0-9A-Z]{8})\.[a-z0-9]+/`,
   with a stem that doesn't change when the file's content does. Keep the
   regex as a test fixture. If a URL falls outside it, translated text
   containing that image is treated as new, which means model calls per
   page and language.
3. **Unresized `<img>` markup stays byte-identical to jekyll-assets'**,
   including `integrity` and `crossorigin` and the attribute order (tag
   attributes, then `src`, `integrity`, `crossorigin`). 128 translated segments
   embed it.
4. **Derivative URLs come from inputs, never from output bytes.**
   - `tkey = sha256(logical path ‖ canonical transform)[0,10]`, the stable stem
   - `dkey = sha256(source sha512 ‖ canonical transform ‖ output settings ‖ PIPELINE_VERSION)`, the 64-hex digest
   - output settings: the `jpeg_quality`/`webp_quality` a transform actually falls back on
   - never part of either key: HTML attributes, argument order, page, build time, libvips version

   **Bump `PIPELINE_VERSION`** when the output of an existing transform should
   change (a kernel, a built-in default). It renames every derivative.
5. **The Jekyll process never loads libvips.** `require "vips"` initialises it,
   and forking after that is unsafe. Use FastImage for dimensions, and spawn
   workers (`Process.spawn`, not `fork`). The only exception is
   `workers: 0`, the in-process mode for tests and debugging.
6. **No threads feeding the workers.** The render thread writes each job
   straight into a worker's stdin and drains results non-blockingly. Measured:
   - worker threads while Liquid renders: 63 images in 5s instead of 205 idle
   - processes behind feeder threads: 68
   - processes fed directly by the render thread: 215 of 220

   Any thread in the parent that has to wake up per job brings the GVL
   problem back.
7. **Scope is what beekeeper uses** (the table in #1). Everything else raises
   "not supported" with the page's path. Don't silently accept an argument and
   do something different from jekyll-assets.
8. **Output is deterministic.** The same input, transform, settings and
   libvips version give the same bytes with any number of workers. Always
   strip metadata; never write timestamps.
9. **Never write into a file in place.**
   - originals in `_site` are copies, never hardlinks: a tool editing `_site`
     must not be able to edit a git-tracked source
   - cache objects are read-only (`0444`) and may be hardlinked
   - every write goes to a temp file, then a rename
10. **The cache is never cleared implicitly.** Not by a missing `_site`, a new
    Jekyll or a missing manifest. GC runs only on full builds (not
    `serve`, `--incremental` or `--limit-posts`) and goes by last use.

## ImageMagick behaviour to mirror (and not)

Mirror:
- `resize='Wx'` enlarges narrower images
- `crop` is clamped to the image, not padded, with no page offset left in the
  output
- `gravity` applies to `crop` wherever it appears among the arguments (checked
  with IM 6.9.12 `mogrify`)

Intended differences, documented in the README:
- convert non-sRGB profiles to sRGB before stripping (only when the profile
  isn't already sRGB)
- autorotate by EXIF
- `jpeg_quality` (82) instead of reusing the source's quality
- flatten alpha onto white for JPEG
- no `integrity` on derivatives by default

Golden tests compare with ImageMagick run directly on the original
(`convert src -resize ... out`), never with jekyll-assets' output: MiniMagick
encodes `format` conversions twice.

## Development environment

- Ruby ≥ 3.1 (beekeeper uses 3.4.4)
- libvips ≥ 8.13:
  - Ubuntu 24.04: `apt-get install libvips42t64`
  - macOS: `brew install vips`

  The Claude Code cloud container has come with libvips 8.15.1 preinstalled
- ImageMagick (`convert`), for golden tests only
- A checkout of beekeeper-studio/web for the harness and parity scripts. Point
  them at it with `BEEKEEPER_WEB=/path/to/web`. Its gems come from `bundle
  install` there, and its Ruby from `mise install`

Commands:
- `bundle exec rake test`: unit, fixture-site, parity and golden tests (all
  run in CI, no beekeeper checkout needed). `bundle exec rubocop` lints
- `bench/originals [BEEKEEPER_WEB]`: builds beekeeper with jekyll-assets and
  `bench/plugins/originals_compare.rb`, which renders every asset tag with
  jekyll-magik too, in the same Liquid context, and compares. It also compares
  every original in the sprockets manifest, seo-assets' URLs and
  `image_size`. About a minute when the site's `_site` has a jekyll-assets
  build (its manifest keeps jekyll-assets' cache); exits 1 on a difference
- `bench/resolver`, run with beekeeper's gems (`cd $BEEKEEPER_WEB && mise exec
  -- bundle exec ruby .../bench/resolver`): tricky names through sprockets and
  through the Resolver
- `script/extract-tags BEEKEEPER_WEB > test/fixtures/beekeeper-tags.json`:
  the tag corpus the parser parity test uses. Regenerate it when beekeeper's
  templates change
- `script/nokogiri-golden`, run with beekeeper's gems: the golden `<img>`
  markup in `test/fixtures/nokogiri-img.json`

Coming with #5:
- `bench/run SITE_DIR`: build timings by scenario and configuration
- `bench/parity A_SITE C_SITE`: HTML and image comparison of two builds
- `bench/segments A_SITE C_SITE`: translated segment keys that changed

A full beekeeper build takes about 2 minutes cold on 4 vCPUs. Run it in the
background and prefer the fixture site and manifest-based scripts for quick
checks.

## Code map and decisions (#1)

- `lib/jekyll/magik/core.rb` loads the classes without registering anything;
  `lib/jekyll/magik.rb` (`plugins: [jekyll-magik]`) registers the tag, the
  filters, `site.magik` and the hooks, and refuses to run next to
  jekyll-assets. The bench plugins load only `core` beside jekyll-assets
- `Plan` parses a tag once, at Liquid parse time, with `Args` (a line-for-line
  port of liquid-tag-parser). The structure (keys, flags) is checked there;
  the error is raised when the tag renders, so it can name the page.
  `Renderer` turns a Plan into markup
- `Resolver` lists each directory at most once per build, on first use,
  instead of globbing every load path up front: jekyll-assets' default load
  paths include site-root directories (`img/`, `js/`, `images/`), which can
  be big trees a site never asks for. Results are memoized per name
- `Mime::EXTS` is sprockets' whole extension table, because it decides which
  files an extensionless name can match. Only `Mime::PASSTHROUGH` types
  (images, audio, video, fonts) are served: sprockets copies those byte for
  byte, so their URLs are provably jekyll-assets'
- HTML attributes: any valid name with a string or number value is written
  as jekyll-assets wrote it (beekeeper uses `style` too). `src`, `integrity`
  and `crossorigin` given in a tag behave as they did in jekyll-assets. Other
  `@flags`, `!flags`, bare words, repeated keys and namespaced keys raise,
  as do jekyll-assets' own keys (`data`, `pic`, `srcset:`, `vips:`, ...)
- `Html` mirrors libxml2 2.13's attribute serialization (entities, quote
  choice, URI escaping of `src`/`href`/`action`, dropped control
  characters); the golden file comes from beekeeper's Nokogiri
- `Svg` edits the root start tag in the file's own text instead of an XML
  round trip, so the rest of the markup is kept byte for byte
- The sprockets corners the Resolver and Source copy: a directory's `index`
  file found by the directory's name gets the directory's name (`only` →
  `img/only.png`, sprockets' index alias), and names sprockets takes as
  digested already (`-1a2b3c4.digested`) get no digest
- Assets are marked used per build, by the tags that render. An incremental
  build skips unchanged pages, so `CleanerMethods` (in `magik.rb`) stops
  Jekyll's cleaner from deleting jekyll-magik's files in incremental builds,
  as jekyll-assets kept its manifest's files. #2's persisted page → assets
  map should replace this with the exact set
- `AssetFile` treats a destination hardlinked to its source as stale, which
  is right for originals. #4's cache objects are meant to be hardlinked and
  skipped when the inode matches, so it needs a policy per kind of asset
- A tag checks its mode against the asset's type before marking it used, so
  a tag that raises writes nothing (and, with #4, starts no job)

## Review every piece of work

For every piece of work (each issue, each PR, each change of any size),
spin up a review agent with no context to review it and find bugs in the
architecture or the implementation. Start a fresh agent, not a fork of your
own session, and give it the code and the spec (this file, the README, the
issue), not your conclusions or what you think is wrong, so its read isn't
anchored on yours. Check each finding yourself before fixing it.

## Conventions

- Unix line endings, 2-space indentation, `# frozen_string_literal: true`
- Tests with minitest. A fixture site in `test/fixtures/site` covers every row
  of #1's scope table
- Error messages name the page (`relative_path`), the source file and the tag
  arguments as written
- Commits and PRs: a short title (about 80 characters), and a description of a
  few simple bullets saying what the change does for a user, not a list of
  code edits. Put `bench/run` numbers in PRs that change performance
