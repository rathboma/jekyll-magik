# frozen_string_literal: true

require_relative "test_helper"

# Issue #2's acceptance criteria, on the fixture site (resized.html has the
# four kinds of transform beekeeper-studio/web uses, and a PNG).
class CacheTest < Minitest::Test
  include MagikTestHelper

  DERIVATIVE_URLS = %r{/assets/[^"'\s<]+-\h{10}-\h{64}\.[a-z0-9]+}
  CACHE = ".jekyll-cache/magik/v1"

  def derivative_urls(dir)
    read_output(dir, "resized.html").scan(DERIVATIVE_URLS)
  end

  # A build in a new Site: a new process, as far as jekyll-magik is
  # concerned (its Store is loaded from disk again).
  def rebuild(dir, config = {})
    site = site_for(dir, config)
    site.process
    site
  end

  def counts(site)
    site.magik.stats.slice(:derivatives, :cached, :processed)
  end

  def object_for(dir, url)
    _, _, dkey, ext = derivative_parts(url)
    File.join(dir, CACHE, "objects", dkey[0, 2], "#{dkey}.#{ext}")
  end

  def index(dir)
    JSON.parse(File.read(File.join(dir, CACHE, "index.json")))
  end

  def write_index(dir, data)
    File.write(File.join(dir, CACHE, "index.json"), JSON.generate(data))
  end

  def with_pipeline_version(version)
    old = Jekyll::Magik::PIPELINE_VERSION
    Jekyll::Magik.send(:remove_const, :PIPELINE_VERSION)
    Jekyll::Magik.const_set(:PIPELINE_VERSION, version)
    yield
  ensure
    Jekyll::Magik.send(:remove_const, :PIPELINE_VERSION)
    Jekyll::Magik.const_set(:PIPELINE_VERSION, old)
  end

  def test_a_build_with_the_cache_and_no_site_processes_nothing
    site, dir = build
    assert_equal({ derivatives: 8, cached: 0, processed: 8 }, counts(site))
    urls = derivative_urls(dir)
    assert_equal 8, urls.size

    # _site deleted between builds
    FileUtils.rm_rf(File.join(dir, "_site"))
    site = rebuild(dir)
    assert_equal({ derivatives: 8, cached: 8, processed: 0 }, counts(site))
    assert_equal urls, derivative_urls(dir)
    urls.each { |u| assert_equal File.stat(object_for(dir, u)).ino, File.stat(File.join(dir, "_site", u)).ino }

    # CI: a fresh checkout (other paths, new mtimes) with the cache restored
    fresh = fixture_copy
    FileUtils.cp_r(File.join(dir, ".jekyll-cache"), fresh)
    site = rebuild(fresh)
    assert_equal({ derivatives: 8, cached: 8, processed: 0 }, counts(site))
    assert_equal urls, derivative_urls(fresh)
  end

  def test_attributes_and_the_order_of_settings_change_no_url
    site = site_for(fixture_copy)
    site.reset
    tags = [
      %({% asset logo.png magick:resize='16x' magick:quality='80' magick:format='jpg' @magick:strip alt="A" %}),
      %({% asset logo.png alt="B" class="x" loading="lazy" magick:format=jpg magick:quality=80 magick:resize=16x %}),
      %({% asset logo.png @magick:strip magick:quality='080' title="t" magick:format='JPEG' magick:resize='16x' @path %}),
      %({% asset img/logo.png magick:format='jpeg' magick:resize='{{ page.w }}x' magick:quality='{{ page.q }}' %})
    ]
    urls = tags.map do |tag|
      render(tag, site: site, assigns: { "w" => 16, "q" => "80" })[%r{/assets/[^"'\s<]+}]
    end
    assert_equal 1, urls.uniq.size, urls.inspect
    assert_equal({ derivatives: 1, cached: 0, processed: 1 }, counts(site))
    assert_equal 4, site.magik.stats[:references]
  end

  def test_a_changed_source_changes_the_dkey_but_not_the_tkey
    _, dir = build
    before = derivative_urls(dir)
    File.binwrite(File.join(dir, "_assets/img/logo.png"), png(12, 8, seed: 9))
    site = rebuild(dir)
    after = derivative_urls(dir)
    assert_equal 2, counts(site)[:processed]
    before.zip(after).each do |old, new|
      old_parts = derivative_parts(old)
      new_parts = derivative_parts(new)
      assert_equal old_parts.values_at(0, 1, 3), new_parts.values_at(0, 1, 3)
      if old.include?("/img/logo-")
        refute_equal old_parts[2], new_parts[2]
        refute File.exist?(File.join(dir, "_site", old)), "#{old} wasn't cleaned"
      else
        assert_equal old, new
      end
    end
  end

  def test_pipeline_version_changes_every_dkey
    _, dir = build
    before = derivative_urls(dir)
    site = with_pipeline_version(Jekyll::Magik::PIPELINE_VERSION + 1) { rebuild(dir) }
    after = derivative_urls(dir)
    assert_equal 8, counts(site)[:processed]
    before.zip(after).each do |old, new|
      assert_equal derivative_parts(old).values_at(0, 1, 3), derivative_parts(new).values_at(0, 1, 3)
      refute_equal derivative_parts(old)[2], derivative_parts(new)[2]
    end
  end

  # Only JPEG output without its own quality uses jpeg_quality: the blog
  # thumbnail and the poster, not the card (quality 80), WebP or PNG.
  def test_jpeg_quality_changes_only_jpegs_that_use_it
    _, dir = build
    before = derivative_urls(dir)
    site = rebuild(dir, "magik" => { "jpeg_quality" => 60 })
    changed = before.zip(derivative_urls(dir)).reject { |old, new| old == new }.map(&:first)
    assert_equal 2, counts(site)[:processed]
    assert_equal %w(/assets/img/blog/default /assets/img/photo), changed.map { |u| u[/\A.*(?=-\h{10}-)/] }.sort
    assert(changed.all? { |u| u.end_with?(".jpg") })
    assert_operator File.size(object_for(dir, derivative_urls(dir).first)), :<, File.size(object_for(dir, before.first))

    site = rebuild(dir, "magik" => { "jpeg_quality" => 60, "webp_quality" => 50 })
    assert_equal 0, counts(site)[:processed], "webp_quality changed output that gives its own quality"
  end

  def test_a_truncated_or_missing_object_is_made_again
    _, dir = build
    urls = derivative_urls(dir)
    truncated = object_for(dir, urls[0])
    missing = object_for(dir, urls[1])
    good = File.binread(truncated)
    File.chmod(0o644, truncated)
    File.truncate(truncated, 10)
    File.unlink(missing)

    site = rebuild(dir)
    assert_equal({ derivatives: 8, cached: 6, processed: 2 }, counts(site))
    assert_equal urls, derivative_urls(dir)
    assert_equal good, File.binread(truncated)
    assert_equal good, File.binread(File.join(dir, "_site", urls[0]))
    assert File.file?(missing)
  end

  def test_a_deleted_or_unreadable_index_is_recovered_from_the_objects
    _, dir = build
    urls = derivative_urls(dir)
    entries = index(dir)
    File.unlink(File.join(dir, CACHE, "index.json"))
    site = rebuild(dir)
    assert_equal({ derivatives: 8, cached: 8, processed: 0 }, counts(site))
    assert_equal(entries.transform_values { |e| e.except("last_used_at") },
                 index(dir).transform_values { |e| e.except("last_used_at") })

    File.write(File.join(dir, CACHE, "index.json"), "{ not json")
    site = rebuild(dir)
    assert_equal 0, counts(site)[:processed]
    assert_equal urls, derivative_urls(dir)
    assert_equal 8, index(dir).size
  end

  def test_an_object_of_the_wrong_size_without_an_entry_is_a_miss
    _, dir = build
    url = derivative_urls(dir).first
    object = object_for(dir, url)
    File.unlink(object)
    File.binwrite(object, png(3, 3))
    write_index(dir, {})
    site = rebuild(dir)
    assert_equal 1, counts(site)[:processed]
    assert_equal [600, 300], FastImage.size(object)
  end

  def test_the_source_memo_saves_hashing_unchanged_files
    _, dir = build
    hashed = []
    original = Digest::SHA512.method(:file)
    Digest::SHA512.stub(:file, lambda { |path|
      hashed << path
      original.call(path)
    }) do
      rebuild(dir)
      assert_empty hashed
      File.binwrite(File.join(dir, "_assets/img/logo.png"), png(12, 8, seed: 3))
      rebuild(dir)
      assert_equal [File.join(dir, "_assets/img/logo.png")], hashed
    end
  end

  def age(dir, days, *paths)
    time = Time.now - (days * 86_400)
    paths.each { |p| File.utime(time, time, p) }
    data = index(dir)
    paths.each do |p|
      dkey = File.basename(p).split(".").first
      data[dkey]["last_used_at"] = time.to_i if data[dkey]
    end
    write_index(dir, data)
  end

  def test_gc_removes_old_unused_objects_only_after_a_full_build
    _, dir = build
    used = object_files(dir)
    objects = File.join(dir, CACHE, "objects")
    old = File.join(objects, "ab", "ab#{"0" * 62}.png")
    recent = File.join(objects, "cd", "cd#{"0" * 62}.png")
    [old, recent].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, png(2, 2))
    end
    data = index(dir)
    data["ab#{"0" * 62}"] = { "ext" => "png", "bytes" => File.size(old), "width" => 2, "height" => 2 }
    write_index(dir, data)
    old_tmp = File.join(objects, ".tmp-old")
    new_tmp = File.join(objects, ".tmp-new")
    File.write(old_tmp, "x")
    File.write(new_tmp, "x")
    age(dir, 30, old, *used)
    File.utime(Time.now - 7200, Time.now - 7200, old_tmp)

    [{ "serving" => true }, { "watch" => true }, { "incremental" => true }, { "limit_posts" => 1 },
     { "magik" => { "gc" => false } }].each do |config|
      rebuild(dir, config)
      assert File.exist?(old), "GC ran with #{config.inspect}"
    end
    rebuild(dir, "magik" => { "gc" => { "max_age_days" => 60 } })
    assert File.exist?(old), "GC removed an object younger than max_age_days"

    rebuild(dir)
    refute File.exist?(old)
    refute index(dir).key?("ab#{"0" * 62}")
    refute File.exist?(old_tmp)
    assert File.exist?(new_tmp)
    assert File.exist?(recent)
    used.each { |path| assert File.exist?(path), "GC removed #{path}, which the build used" }
    assert_equal 8, index(dir).size, "an object without an entry is kept, without one"
  end

  # The page map puts back the assets of pages an incremental build skips,
  # and only those: assets nothing uses any more are cleaned as usual.
  def test_an_incremental_build_keeps_exactly_the_assets_of_skipped_pages
    _, dir = build(config: { "incremental" => true })
    png_url = element(read_output(dir, "resized.html"), "png")
    stale = File.join(dir, "_site/assets/img/stale-#{"a" * 10}-#{"b" * 64}.png")
    File.write(stale, "x")

    page = File.join(dir, "resized.html")
    File.write(page, File.read(page).sub(/^<p id="png">.*\n/, ""))
    site = rebuild(dir, "incremental" => true)
    assert_equal 7, site.magik.stats[:references], "only resized.html should render"
    refute File.exist?(File.join(dir, "_site", png_url)), "the dropped image is still there"
    refute File.exist?(stale)
    (read_output(dir) + read_output(dir, "resized.html")).scan(%r{/assets/[^"'\s<]+}).each do |u|
      assert File.file?(File.join(dir, "_site", u)), u
    end

    # Without the page map (the cache was deleted), every file of
    # jekyll-magik's is kept, as jekyll-assets kept its manifest's.
    File.write(stale, "x")
    FileUtils.rm_rf(File.join(dir, ".jekyll-cache/magik"))
    rebuild(dir, "incremental" => true)
    assert File.exist?(stale)
    read_output(dir).scan(%r{/assets/[^"'\s<]+}).each { |u| assert File.file?(File.join(dir, "_site", u)), u }
  end

  # Each quality setting goes into the content key only of output that
  # uses it: JPEGs and WebPs without their own quality.
  def test_quality_settings_change_only_output_that_uses_them
    dir = fixture_copy
    tags = {
      webp: %({% asset shot.webp magick:resize='4x' @path %}),
      webp_q: %({% asset shot.webp magick:resize='4x' magick:quality='80' @path %}),
      jpg: %({% asset photo.jpg magick:resize='4x' @path %}),
      png: %({% asset logo.png magick:resize='4x' @path %})
    }
    urls = lambda do |magik|
      site = site_for(dir, "magik" => magik)
      site.reset
      tags.transform_values { |tag| render(tag, site: site) }
    end
    base = urls.call({})
    assert_equal base.merge(webp: urls.call("webp_quality" => 50)[:webp]), urls.call("webp_quality" => 50)
    refute_equal base[:webp], urls.call("webp_quality" => 50)[:webp]
    jpeg = urls.call("jpeg_quality" => 50)
    assert_equal base.except(:jpg), jpeg.except(:jpg)
    refute_equal base[:jpg], jpeg[:jpg]
  end

  def test_a_malformed_page_map_falls_back_to_keeping_every_file
    _, dir = build(config: { "incremental" => true })
    files = Dir.glob(File.join(dir, "_site/assets/**/*")).select { |f| File.file?(f) }
    pages = File.join(dir, CACHE, "pages.json")
    data = JSON.parse(File.read(pages))
    data[File.join(dir, "resized.html")] = [%w(d x), ["o"], "junk", ["d", 1, 2, 3]]
    File.write(pages, JSON.generate(data))
    rebuild(dir, "incremental" => true)
    files.each { |f| assert File.file?(f), "#{f} was deleted" }
  end

  def test_the_manifest
    site, dir = build(config: { "magik" => { "manifest" => true } })
    manifest = JSON.parse(read_output(dir, "assets/magik-manifest.json"))
    assert_equal 11, manifest["originals"].size
    assert_equal({ "logical_path" => "img/logo.png" }, manifest["originals"][site.magik.lookup("logo.png").url])
    assert_equal derivative_urls(dir).sort, manifest["derivatives"].keys
    thumb = manifest["derivatives"][element(read_output(dir, "resized.html"), "thumb")[DERIVATIVE_URLS]]
    assert_equal({ "logical_path" => "img/blog/default.jpg",
                   "transform" => { "gravity" => "center", "ops" => [%w(resize 600x), %w(crop 600x300+0+0)] },
                   "width" => 600, "height" => 300 }, thumb)

    # An incremental build that renders nothing lists the same assets.
    json = read_output(dir, "assets/magik-manifest.json")
    rebuild(dir, "magik" => { "manifest" => true }, "incremental" => true)
    rebuild(dir, "magik" => { "manifest" => true }, "incremental" => true)
    assert_equal json, read_output(dir, "assets/magik-manifest.json")

    rebuild(dir)
    refute File.exist?(File.join(dir, "_site/assets/magik-manifest.json"))
  end

  def test_derivative_integrity
    _, dir = build(config: { "magik" => { "derivative_integrity" => true } })
    card = element(read_output(dir, "resized.html"), "card")
    url = card[DERIVATIVE_URLS]
    integrity = "sha512-#{[Digest::SHA512.file(File.join(dir, "_site", url)).digest].pack("m0")}"
    assert_equal %(<img class="card" alt="Card" loading="lazy" src="#{url}" integrity="#{integrity}" \
crossorigin="anonymous">), card
    assert_equal Digest::SHA512.file(File.join(dir, "_site", url)).hexdigest,
                 index(dir)[derivative_parts(url)[2]]["sha512"]
  end

  def test_copies_when_hardlinks_cant_be_made
    site = nil
    dir = nil
    File.stub(:link, ->(*) { raise Errno::EXDEV }) { site, dir = build }
    url = derivative_urls(dir).first
    out = File.join(dir, "_site", url)
    refute_equal File.stat(object_for(dir, url)).ino, File.stat(out).ino
    assert_equal File.binread(object_for(dir, url)), File.binread(out)
    inode = File.stat(out).ino
    File.stub(:link, ->(*) { raise Errno::EXDEV }) { site.process }
    assert_equal inode, File.stat(out).ino, "an up-to-date copy was written again"
  end

  def test_a_failed_resize_names_the_source_the_transform_and_the_page
    dir = fixture_copy("_assets/img/broken.png" => png(4, 4).byteslice(0, 40),
                       "broken.html" => "---\n---\n{% asset broken.png magick:resize='2x' @path %}\n")
    site = site_for(dir)
    error = assert_raises(Jekyll::Magik::Error) { site.process }
    assert_match(/can't (?:resize|read the size of) img\/broken\.png/, error.message)
    assert_includes error.message, "in broken.html ({% asset broken.png magick:resize='2x' @path %})"
    assert_empty object_files(dir)
  end
end
