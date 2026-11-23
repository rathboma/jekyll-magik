# frozen_string_literal: true

require_relative "test_helper"

# Builds test/fixtures/site, which uses every row of the scope table in #1.
class FixtureSiteTest < Minitest::Test
  include MagikTestHelper

  def setup
    @site, @dir = build
    @html = read_output(@dir)
    @assets = File.join(@dir, "_assets")
  end

  def url(logical_path, file = logical_path)
    digest = sha512(File.join(@assets, file))
    "/assets/#{logical_path.sub(/\.(\w+)\z/) { "-#{digest}#{$&}" }}"
  end

  def integrity(file)
    "sha512-#{[Digest::SHA512.file(File.join(@assets, file)).digest].pack("m0")}"
  end

  def img_tail(logical_path, file = "img/#{logical_path.delete_prefix("img/")}")
    %(src="#{url(logical_path, file)}" integrity="#{integrity(file)}" crossorigin="anonymous">)
  end

  def test_jpg_png_gif_webp_and_svg_images
    assert_equal %(<img alt="A photo" #{img_tail("img/photo.jpg")}), element(@html, "jpg")
    assert_equal %(<img alt="Logo" class="logo" height="42" #{img_tail("img/logo.png")}), element(@html, "png")
    assert_equal %(<img #{img_tail("img/anim.gif")}), element(@html, "gif")
    assert_equal %(<img title="Tom &amp; Jerry's &lt;show&gt;" loading="lazy" #{img_tail("img/shot.webp")}),
                 element(@html, "webp")
    assert_equal %(<img alt="" width="300" #{img_tail("img/hero.svg")}), element(@html, "svg-img")
  end

  def test_names_without_an_extension_pick_the_first_file_in_sorted_order
    assert_equal %(<img #{img_tail("img/home/edit-schema.jpg")}), element(@html, "extensionless")
  end

  def test_a_logical_path_and_a_nested_load_path_name_the_same_file
    assert_equal %(<img alt="By logical path" #{img_tail("img/home/edit-schema.png")}), element(@html, "logical")
    assert_equal %(<img alt='HOME &amp; "WELCOME"' #{img_tail("img/blog/default.jpg")}), element(@html, "nested")
  end

  def test_liquid_in_the_name_quoted_or_not
    assert_equal url("img/home/edit-schema.jpg"), element(@html, "liquid-name")
    assert_equal url("img/home/edit-schema.svg"), element(@html, "quoted-liquid-name")
  end

  def test_mp4_with_path
    assert_equal url("videos/clip.mp4"), element(@html, "mp4")
    assert_equal url("videos/clip.mp4"), element(@html, "mp4-load-path")
  end

  def test_filters
    assert_equal url("img/logo.png"), element(@html, "url-filter")
    assert_equal "8x6", element(@html, "size-filter")
  end

  def test_inline_svg
    assert_equal <<~SVG.strip, element(@html, "inline")
      <!-- Generator: a test, like Adobe Illustrator's -->
      <svg version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg" x="0px" y="0px"
      \t viewBox="0 0 40 20" width="40" height="20" class="hero" aria-label="Hero">
      <rect fill="#FAD83B" x="0" y="0" width="40" height="20"/>
      </svg>
    SVG
  end

  def test_liquid_in_attributes_from_an_include
    assert_equal %(<figure><img class="figure-img" alt="From an include" #{img_tail("img/logo.png")}</figure>),
                 element(@html, "include")
  end

  def test_an_asset_looked_up_through_the_api_is_written
    assert_includes @html, %(<meta property="og:image" content="#{url("img/og-only.png")}">)
    assert File.file?(File.join(@dir, "_site", url("img/og-only.png")))
  end

  def test_writes_exactly_the_used_assets_as_copies
    logical = %w(
      img/photo.jpg img/logo.png img/anim.gif img/shot.webp img/hero.svg img/home/edit-schema.jpg
      img/home/edit-schema.png img/home/edit-schema.svg img/blog/default.jpg img/og-only.png videos/clip.mp4
    )
    site_assets = File.join(@dir, "_site", "assets")
    written = Dir.glob("**/*", base: site_assets).select { |f| File.file?(File.join(site_assets, f)) }
    originals = written.grep_v(/-\h{10}-\h{64}\.[a-z]+\z/)
    assert_equal logical.map { |l| url(l).delete_prefix("/assets/") }.sort, originals.sort
    assert_equal 8, (written - originals).size

    logical.each do |l|
      out = File.join(@dir, "_site", url(l))
      src = File.join(@assets, l)
      assert_equal File.binread(src), File.binread(out), l
      refute_equal File.stat(src).ino, File.stat(out).ino, "#{l} is a hardlink to its source"
      assert_equal File.stat(src).mtime, File.stat(out).mtime, l
    end
  end

  def test_every_url_matches_the_translation_workers_digest_grammar
    urls = (@html + read_output(@dir, "resized.html")).scan(%r{/assets/[^"'\s<]+})
    assert_operator urls.size, :>=, 23
    urls.each do |u|
      match = DIGESTED.match(u)
      assert match, "#{u} doesn't match the digest grammar"
      assert_equal u, match[0]
    end
  end

  RESIZED = {
    "thumb" => ["img/blog/default", "jpg", [600, 300]],
    "to-webp" => ["img/logo", "webp", [24, 16]],
    "poster" => ["img/photo", "jpg", [64, 48]],
    "card" => ["img/logo", "jpg", [16, 11]],
    "png" => ["img/home/edit-schema", "png", [8, 6]]
  }.freeze

  def test_resized_images
    html = read_output(@dir, "resized.html")
    urls = RESIZED.to_h { |id, _| [id, element(html, id)[%r{/assets/[^"'\s<]+}]] }
    # Derivatives get no integrity, though originals have it in this site.
    assert_equal %(<img alt='Resized &amp; "converted"' src="#{urls["thumb"]}">), element(html, "thumb")
    assert_equal %(<img class="card" alt="Card" loading="lazy" src="#{urls["card"]}">), element(html, "card")
    assert_equal urls["poster"], element(html, "poster")
    RESIZED.each do |id, (stem, ext, size)|
      parts = derivative_parts(urls[id])
      assert_equal [stem, ext], parts.values_at(0, 3), id
      assert_equal size, FastImage.size(File.join(@dir, "_site", urls[id])), id
    end
    srcset = element(html, "srcset").split
    assert_equal([[4, 2], [8, 4], [12, 6]], srcset.map { |u| FastImage.size(File.join(@dir, "_site", u)) })
    # Each width has its own stem, so the translation Worker tells them apart.
    assert_equal 3, srcset.map { |u| derivative_parts(u)[0, 2] }.uniq.size
  end

  def test_resized_images_are_read_only_hardlinks_to_the_cache
    files = Dir.glob(File.join(@dir, "_site/assets/**/*-*-*.*")).grep(/-\h{10}-\h{64}\./)
    assert_equal 8, files.size
    files.each do |f|
      dkey, ext = File.basename(f)[/-(\h{64}\.\w+)\z/, 1].split(".")
      object = File.join(@dir, ".jekyll-cache/magik/v1/objects", dkey[0, 2], "#{dkey}.#{ext}")
      assert_equal File.stat(object).ino, File.stat(f).ino, f
      assert_equal 0o444, File.stat(object).mode & 0o777
    end
  end

  def test_a_rebuild_keeps_the_files_and_rewrites_nothing
    files = Dir.glob(File.join(@dir, "_site", "assets", "**", "*")).select { |f| File.file?(f) }
    before = files.to_h { |f| [f, File.stat(f).ino] }
    site_for(@dir).process
    files.each { |f| assert_equal before[f], File.stat(f).ino, "#{f} was rewritten" }
  end

  def test_a_changed_image_gets_a_new_url_and_the_old_file_is_cleaned
    old = url("img/logo.png")
    FileUtils.cp(File.join(@assets, "img/photo.jpg"), File.join(@assets, "img/logo.png"))
    site_for(@dir).process
    html = read_output(@dir)
    refute_includes html, old
    assert_includes html, url("img/logo.png")
    refute File.exist?(File.join(@dir, "_site", old))
  end

  # An incremental build skips unchanged pages, so their tags don't run; the
  # cleaner mustn't delete their images.
  def test_an_incremental_rebuild_keeps_the_assets_of_skipped_pages
    _, dir = build(config: { "incremental" => true })
    files = Dir.glob(File.join(dir, "_site/assets/**/*")).select { |f| File.file?(f) }
    assert_equal 19, files.size
    site = site_for(dir, "incremental" => true)
    site.process
    assert_equal 0, site.magik.stats[:references], "pages were rendered again"
    files.each { |f| assert File.file?(f), "#{f} was deleted" }
    html = read_output(dir) + read_output(dir, "resized.html")
    html.scan(%r{/assets/[^"'\s<]+}).each { |u| assert File.file?(File.join(dir, "_site", u)), u }

    # A full build still cleans up what nothing uses any more.
    stale = File.join(dir, "_site/assets/img/stale-#{"a" * 128}.png")
    File.write(stale, "x")
    site_for(dir).process
    refute File.exist?(stale)
  end

  def test_baseurl
    site, dir = build(config: { "baseurl" => "/docs/" })
    html = read_output(dir)
    assert_equal "/docs#{url("videos/clip.mp4")}", element(html, "mp4")
    assert_includes element(html, "jpg"), %(src="/docs#{url("img/photo.jpg")}")
    # Files still go under the destination, not under the baseurl.
    assert File.file?(File.join(dir, "_site", url("img/photo.jpg")))
    assert_equal "/docs/assets", site.magik.config.url_for(nil)
  end

  def test_a_custom_destination
    _, dir = build(config: { "assets" => { "sources" => ["_assets"], "destination" => "/static/a/",
                                           "defaults" => { "img" => { "integrity" => false } } } })
    html = read_output(dir)
    expected = url("img/photo.jpg").sub("/assets/", "/static/a/")
    assert_equal %(<img alt="A photo" src="#{expected}">), element(html, "jpg")
    assert File.file?(File.join(dir, "_site", expected))
  end
end

class FixtureSiteErrorsTest < Minitest::Test
  include MagikTestHelper

  def build_error(page)
    error = assert_raises(Jekyll::Magik::Error) { build(files: { "broken.html" => "---\n---\n#{page}\n" }) }
    error.message
  end

  def test_an_unknown_asset_names_the_page_and_the_tag
    assert_equal "Unknown asset 'nope.png' in broken.html ({% asset nope.png alt=\"x\" %})",
                 build_error(%({% asset nope.png alt="x" %}))
  end

  def test_an_unknown_asset_from_liquid
    assert_match(/\AUnknown asset 'missing' in broken.html/, build_error(%({% asset {{page.nope}}missing %})))
  end

  def test_out_of_scope_arguments_name_the_page
    {
      %({% asset logo.png @data %}) => "`@data` (data URIs) isn't supported",
      %({% asset logo.png magick:rotate='90' %}) => "`magick:rotate` isn't supported",
      %({% asset main.css %}) => "stylesheets (.css) aren't supported",
      %({% asset logo.png @inline %}) => "`@inline` only supports SVG files",
      %({% asset clip.mp4 %}) => "video/mp4 assets can only be used with `@path`"
    }.each do |tag, message|
      error = build_error(tag)
      assert_includes error, message
      assert_includes error, "in broken.html (#{tag})"
    end
  end

  def test_the_assets_drop_raises
    error = build_error(%({{ assets["logo.png"].width }}))
    assert_includes error, "the `assets` drop"
  end

  def test_the_api_raises_for_an_unknown_asset
    site = site_for(fixture_copy)
    site.reset
    error = assert_raises(Jekyll::Magik::UnknownAsset) { site.magik.find!("nope.png") }
    assert_equal "Unknown asset 'nope.png'", error.message
    assert_nil site.magik.find("nope.png")
  end
end
