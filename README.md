# jekyll-magik

Fast image processing for Jekyll, with libvips, as a drop-in replacement for
the image side of [jekyll-assets](https://github.com/envygeeks/jekyll-assets).
Your `{% asset %}` tags, including their `magick:` resize and crop arguments,
keep working. The build stops spending minutes in ImageMagick.

> **Status: in progress.** Parts 1 and 2
> ([#1](https://github.com/rathboma/jekyll-magik/issues/1),
> [#2](https://github.com/rathboma/jekyll-magik/issues/2)) work: the tag,
> `@path`, `@inline`, the filters and the Ruby API, with jekyll-assets' exact
> URLs and markup for files used as they are, and `magick:` resizing with the
> global cache and stable URLs described below. For now each new image is
> resized by one worker process while its tag waits, with a plain libvips
> pipeline: [#3](https://github.com/rathboma/jekyll-magik/issues/3) makes the
> output match ImageMagick's (colour profiles, golden tests) and
> [#4](https://github.com/rathboma/jekyll-magik/issues/4) runs a pool of
> workers in the background. The rest of this README describes the whole
> design in issues #1 to [#6](https://github.com/rathboma/jekyll-magik/issues/6),
> and changes as each part lands. There's no release yet; install from git.

## Why

On the [Beekeeper Studio website](https://github.com/beekeeper-studio/web), the
first site to use it, jekyll-assets is most of the build time. Measured with
4 vCPUs, Ruby 3.4, ImageMagick 6.9 and libvips 8.15:

| Build | jekyll-assets | jekyll-magik target |
|---|---|---|
| Cold: no cache, no `_site` | 131s | ≤ 33s |
| CI: cache restored, no `_site` | 134s (the cache is wiped) | ≤ 24s |
| Local rebuild: cache and `_site` | 38.7s | ≤ 24s |
| With every asset tag stubbed out (the floor) | 21.3s | 21.3s |

Where the time goes:

- **The resizes.** That build makes 591 resized images. ImageMagick spends
  90.8s on them, one `mogrify` process at a time, inside Liquid rendering.
  libvips does the same 591 in 33.7s on one core and 10.5s on four.
- **Per-tag overhead.** jekyll-assets also spends ~19s on sprockets lookups
  across the build's 5,393 asset tag renders, and it pays that even with a
  warm cache.
- **Wiped caches.** It throws away its cache whenever `_site` has no sprockets
  manifest, which is every CI build.

The targets are overhead over the floor: at most 12s cold, at most 3s warm.
The benchmark table will be filled in from `bench/run` as the parts land
([#5](https://github.com/rathboma/jekyll-magik/issues/5)).

## How it works

- **One global cache.** Every processed image is stored once in
  `.jekyll-cache/magik`, keyed by the source file's content and the normalized
  transform. It is never keyed by the page, the order of the arguments, HTML
  attributes or the build time. An image used on 300 pages is looked up once
  per build and processed once per change to its source. A missing `_site`
  doesn't clear the cache.
- **URLs before pixels.** A resized image's URL is computed from its inputs, so
  the tag can return at once and the image be processed in the background
  (#4; until then the tag waits for it).
- **libvips in worker processes.** Images are resized by a pool of worker
  processes while Jekyll renders pages on the main thread. Threads don't work
  for this: the render thread holds Ruby's GVL and starves libvips threads of
  it (63 images in 5s instead of 205). The Jekyll process itself never loads
  libvips, so a site that doesn't resize anything doesn't need it installed.
- **Stable URLs.** Files used as they are keep exactly the URLs jekyll-assets
  gave them. A resized image's URL changes only when its source or its
  arguments change, not when libvips is upgraded.

## Requirements

- Ruby ≥ 3.1 and Jekyll 4.3 or newer
- libvips ≥ 8.13, only if you resize images:
  - Ubuntu 24.04: `sudo apt-get install --no-install-recommends libvips42t64`
  - older Ubuntu and Debian: `libvips42`
  - macOS: `brew install vips`
  - Alpine: `apk add vips`

## Installation

```ruby
# Gemfile
group :jekyll_plugins do
  gem "jekyll-magik", git: "https://github.com/rathboma/jekyll-magik"
end
```

```yaml
# _config.yml
plugins:
  - jekyll-magik
```

Remove jekyll-assets first: both define `{% asset %}`, and jekyll-magik refuses
to load next to it.

## Syntax

Images live in the asset source directories: the `assets.sources` you
configure (such as `_assets`), plus jekyll-assets' defaults such as
`_assets/img` and `_assets/images`. Name an image relative to any of them, with
or without its extension.

### An image

```liquid
{% asset blog/default.jpg alt="Beekeeper Studio" loading="lazy" %}
```

```html
<img alt="Beekeeper Studio" loading="lazy" src="/assets/img/blog/default-<sha512>.jpg">
```

HTML attributes (`alt`, `class`, `width`, `height`, `loading`, `title`,
`style`, ...) are written in the order given, then `src`, then `integrity`
and `crossorigin` when `assets: defaults: img: integrity` is on: byte for
byte what jekyll-assets wrote, escaping and quoting included. Liquid works in
any value, and in the name:

```liquid
{% asset {{ post.image.asset }} alt="{{ post.title | escape }}" %}
{% asset '{{ include.asset }}' class="lightbox-img" %}
```

### Just the URL: `@path`

```liquid
<a href="{% asset screenshots/main-dark.png @path %}">
<video src="{% asset {{ include.clip }}.mp4 @path %}"></video>
```

### SVG markup: `@inline`

```liquid
{% asset databases/heros/postgres-client.svg @inline %}
```

This writes the SVG's own markup into the page, with any attributes from the
tag set on its root `<svg>` element. The file is kept as it is (attribute
case such as `viewBox` included), except that its XML declaration and doctype
are dropped. jekyll-assets re-serialized it and ignored the tag's attributes.

### Resizing: `magick:`

The arguments are jekyll-assets' ImageMagick syntax, done by libvips.

```liquid
{% asset blog/post.png magick:resize='600x' magick:crop='600x300+0+0' magick:gravity='center' @magick:strip alt="..." %}
{% asset screenshots/main-dark.png magick:resize='750x' magick:format='webp' magick:quality='80' @magick:strip @path %}
```

| Argument | Meaning |
|---|---|
| `magick:resize='Wx'` | W pixels wide, keeping the aspect ratio. Like ImageMagick, it enlarges a narrower image |
| `magick:crop='WxH+X+Y'` with `magick:gravity='center'` | a W×H box from the centre, offset by X/Y and clamped to the image |
| `magick:quality='N'` | JPEG or WebP quality, 1–100 |
| `magick:format='webp'` or `'jpg'` | convert; the URL's extension follows |
| `@magick:strip` | accepted. Metadata is always stripped |

Sources can be PNG, JPEG or WebP. `resize` and `crop` run in the order given,
as ImageMagick runs them; the order of the other arguments, quoting
(`'600x'` or `600x`) and HTML attributes don't matter.

A resized image's URL is

```
/assets/<dir>/<name>-<transform key>-<content key>.<ext>
/assets/img/screenshots/main-dark-3f9c1a7e2b-<64 hex>.webp
```

- The **transform key** (10 hex) comes from the source's logical path and the
  arguments, normalized. It doesn't change when the image does, and differs
  for each width in a srcset.
- The **content key** (64 hex) comes from the source's bytes, the arguments,
  the output format, the quality setting the output falls back on
  (`jpeg_quality` or `webp_quality`, when the tag gives no `quality`), the
  EXIF rotation applied (below) and `PIPELINE_VERSION`, a number bumped when jekyll-magik's output for the same
  arguments should change. The libvips version isn't part of it, so upgrading
  libvips renames nothing.

Neither comes from the output's bytes, so a URL is known before the image
is made, and the same arguments give the same URL on every machine.

### Differences from jekyll-assets and ImageMagick

These are deliberate:

- **Colour** (arrives with #3): images with a non-sRGB colour profile (for
  example Display P3 screenshots from a Mac) are converted to sRGB before the
  profile is stripped. ImageMagick's `-strip` drops the profile unconverted,
  which washes the colours out.
- **Orientation**: JPEGs are rotated according to their EXIF orientation
  first (an orientation outside 1 to 8 is ignored, as browsers ignore it).
  Other formats are left as they are stored, as ImageMagick leaves them.
- **JPEG quality**: ImageMagick reuses the source's quality, so a q100 source
  makes q100 thumbnails. jekyll-magik uses `magik.jpeg_quality` (82) unless the
  tag gives `quality`.
- **Transparency into JPEG**: flattened onto white.
- **Integrity**: resized images get no `integrity` attribute, since browsers
  don't check it on `<img>`. Turn it on with `magik.derivative_integrity`.
  Images used as they are keep jekyll-assets' `integrity` and `crossorigin`
  when `assets.defaults.img.integrity` is on.

### Not supported

jekyll-magik supports what the Beekeeper Studio site uses. Everything else
raises an error naming the page, rather than doing something different from
jekyll-assets:

- **Asset types**: stylesheets and scripts (`.css`, `.scss`, `.js`). Use
  Jekyll's own Sass support and a JS bundler.
- **Other modes**: `@data`, `@inline` on non-SVG files, and jekyll-assets'
  `<video>`/`<audio>` builders. `@path` works for images, video, audio and
  fonts; an `<img>` for PNG, JPEG, WebP, GIF and SVG.
- **Other arguments**: `@` flags other than `@path` and `@inline`, `!` flags,
  an attribute without a value or given twice, and external URLs.
- **Other features**: the `asset` filter, `responsive:` srcsets, `@pic`, the
  `{{ assets[...] }}` drop, `.liquid` assets, `cdn:`, `precompile` and gzip.
- **Other resize syntax**: `vips:` arguments, and `magick:` keys or geometries
  not listed above (`extent`, `rotate`, `xH`, `WxH!`, `50%`, ...).

Anything here can be added when a site needs it: open an issue.

## Configuration

```yaml
assets:                      # the jekyll-assets keys jekyll-magik reads
  sources:
    - _assets
  destination: /assets
  defaults:
    img:
      integrity: true        # integrity + crossorigin on <img> for unresized images

magik:                       # everything below is optional; these are the defaults
  cache_dir: .jekyll-cache/magik
  workers: 3                 # resize processes; default: CPU count - 1, at least 1
                             # (one for now, #4 makes it a pool); 0 resizes in Jekyll's own process
  jpeg_quality: 82           # for JPEG output without magick:quality
  webp_quality: 75           # for WebP output without magick:quality
  derivative_integrity: false
  manifest: false            # write <destination>/magik-manifest.json, listing every asset URL
  gc:
    max_age_days: 14         # drop cached images unused for this long (false: never)
```

Changing `jpeg_quality` or `webp_quality` re-renders only the images that use
the default, under new URLs.

`manifest: true` writes `_site/assets/magik-manifest.json`: every original's
URL with its logical path, and every resized image's URL with its logical
source path, normalized arguments and size. It's for comparing builds and
making redirects, and is published with the site.

Each build ends with a summary:

```
jekyll-magik: 591 derivatives (589 cached, 2 processed in 0.4s), 456 originals
```

## Ruby API and filters

For plugins that need an asset's URL or size (social images, JSON-LD, `width`
and `height` attributes):

```ruby
asset = site.magik.find!("blog/default.jpg")   # raises if it doesn't exist
asset.url                                        # "/assets/img/blog/default-<sha512>.jpg"
asset.width                                      # 1200
asset.height                                     # 630
site.magik.url("blog/default.jpg")               # the same URL
site.magik.find("nope.png")                      # nil
```

```liquid
{{ "blog/default.jpg" | asset_url }}
{% assign size = "screenshots/main-dark.png" | asset_size %}
<img src="..." width="{{ size[0] }}" height="{{ size[1] }}">
```

Looking an asset up with `find`, `find!`, `url` or `asset_url` also makes sure
it's written to `_site`, even if no tag uses it. `asset_size` only reads the
file's header.

## The cache

Resized images are kept in `.jekyll-cache/magik` (`cache_dir`):

```
.jekyll-cache/magik/v1/objects/3f/3f9c...e1.webp   each image, read-only, named by its content key
.jekyll-cache/magik/v1/index.json                  size and last use of each image
.jekyll-cache/magik/v1/sources.json                digests and sizes of source images, so an
                                                   unchanged file isn't read again
.jekyll-cache/magik/v1/pages.json                  which page used which image
```

- Images are **hardlinked** into `_site` (copied if the cache is on another
  filesystem), so a build with the cache writes them almost for free. Files
  used as they are are always copied.
- Nothing clears it implicitly: not a missing `_site`, a new Jekyll or a
  changed config. `jekyll clean` removes it with the rest of `.jekyll-cache`
  (a `cache_dir` elsewhere stays).
- The JSON files only speed things up. If they're lost or unreadable, the
  images are found from their file names again; an image that is missing or
  cut short is made again.
- **GC**: at the end of a full `jekyll build`, images this build didn't use
  and that no build has used for `gc.max_age_days` are deleted. Never during
  `jekyll serve`, `--watch`, `--incremental` or `--limit-posts` builds, which
  don't use every image.
- **Incremental builds** keep the images of the pages they skip: `pages.json`
  says which they were. (jekyll-assets deleted them.)
- Builds that share a cache can run at once: each merges its changes with the
  others' when it saves.

### Caching in CI

The cache is safe to restore from any earlier build: entries are addressed by
their content, and old ones are removed after `gc.max_age_days`.

```yaml
- uses: actions/cache/restore@v4
  with:
    path: .jekyll-cache/magik
    key: magik-${{ github.run_id }}
    restore-keys: magik-
- run: bundle exec jekyll build
- uses: actions/cache/save@v4
  with:
    path: .jekyll-cache/magik
    key: magik-${{ github.run_id }}
```

## Migrating from jekyll-assets

1. Move stylesheets to Jekyll's own Sass support (or a bundler). jekyll-magik
   doesn't compile them.
2. Swap the gems: remove `jekyll-assets` and `mini_magick`, add `jekyll-magik`.
   Replace `jekyll-assets` with `jekyll-magik` in `plugins:`.
3. Replace `site.sprockets` in your plugins with `site.magik` (above).
4. Install libvips where you build.
5. Expect every resized image's URL to change once. jekyll-magik can't
   reproduce ImageMagick's bytes, and jekyll-assets' names depended on them.
   Unresized files keep their URLs. `bench/parity` lists the old and new URLs
   so you can add redirects.

## Development

See [CLAUDE.md](CLAUDE.md) for the architecture, the rules the code must keep
and how to test against a real site.

```bash
bundle install
bundle exec rake test
bundle exec rubocop
```
