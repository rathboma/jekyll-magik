# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  include MagikTestHelper

  Store = Jekyll::Magik::Store

  def setup
    @dir = Dir.mktmpdir("magik-store-")
    (@tmpdirs ||= []) << @dir
  end

  def store
    Store.new(@dir)
  end

  def put_object(store, dkey, width: 2, height: 2)
    path = store.object_path(dkey, "png")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, png(width, height))
    store.record(dkey, ext: "png", bytes: File.size(path), width: width, height: height)
    path
  end

  def saved(name)
    JSON.parse(File.read(File.join(@dir, "v1", name)))
  end

  # Two processes that loaded the store before either saved: both keep
  # their entries, and the later last use wins.
  def test_concurrent_saves_merge
    a = store
    b = store
    put_object(a, "aa#{"1" * 62}")
    put_object(b, "bb#{"2" * 62}")
    a.use("aa#{"1" * 62}")
    b.use("aa#{"1" * 62}")
    a.update_page("/site/a.html", [["o", "img/a.png", "img/a-x.png"]])
    b.update_page("/site/b.html", [])
    a.save(full_build: false, site_source: "/site", now: 100)
    b.save(full_build: false, site_source: "/site", now: 50)

    index = saved("index.json")
    assert_equal %W[aa#{"1" * 62} bb#{"2" * 62}], index.keys
    assert_equal 100, index["aa#{"1" * 62}"]["last_used_at"]
    assert_equal %w(/site/a.html /site/b.html), saved("pages.json").keys
    assert_equal 2, store.instance_variable_get(:@index).size
  end

  def test_fetch_checks_the_entry_against_the_object
    s = store
    dkey = "cc#{"3" * 62}"
    path = put_object(s, dkey, width: 4, height: 3)
    assert s.fetch(dkey, "png", 4, 3)
    assert_nil s.fetch(dkey, "png", 4, 4), "an entry for another size is a hit"
    assert_nil s.fetch(dkey, "webp", 4, 3)
    assert s.fetch(dkey, "png", 4, 3), "the object without an entry is a hit"
    File.write(path, "")
    assert_nil s.fetch(dkey, "png", 4, 3)
  end

  # Full builds drop this site's entries that the build didn't see, and
  # anyone's whose file is gone (another checkout sharing the cache).
  def test_only_full_builds_prune_the_memo_and_pages
    site = File.join(@dir, "site")
    other = File.join(@dir, "other")
    [site, other].each { |d| FileUtils.mkdir_p(d) }
    %w(site/old.png site/gone.html site/index.html other/a.png other/page.html).each do |f|
      File.write(File.join(@dir, f), "x")
    end
    path = ->(f) { File.join(@dir, f) }
    s = store
    stat = File.stat(__FILE__)
    s.remember_source(path.call("site/old.png"), stat, "sha512" => "x")
    s.remember_source(path.call("other/a.png"), stat, "sha512" => "y")
    s.remember_source(path.call("other/deleted.png"), stat, "sha512" => "z")
    %w(site/gone.html other/page.html other/deleted.html).each { |f| s.update_page(path.call(f), []) }
    s.save(full_build: false, site_source: site)

    s = store
    s.update_page(path.call("site/index.html"), [])
    live = Set[path.call("site/index.html")]
    s.save(full_build: false, site_source: site, live_pages: live)
    assert_equal 3, saved("sources.json").size
    assert_equal 4, saved("pages.json").size

    s.save(full_build: true, site_source: site, live_pages: live)
    assert_equal [path.call("other/a.png")], saved("sources.json").keys
    assert_equal [path.call("other/page.html"), path.call("site/index.html")], saved("pages.json").keys
  end

  # Without an index entry, an object is only taken if it's whole:
  # FastImage reads nothing but the header.
  def test_an_object_without_an_entry_must_be_whole
    s = store
    fixtures = File.join(FIXTURE, "_assets/img")
    { "png" => ["logo.png", [12, 8]], "jpg" => ["photo.jpg", [8, 6]], "webp" => ["shot.webp", [10, 5]] }
      .each_with_index do |(ext, (file, size)), i|
        bytes = File.binread(File.join(fixtures, file))
        dkey = "e#{i}#{"0" * 62}"
        path = s.object_path(dkey, ext)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes.byteslice(0, bytes.bytesize - 3))
        assert_nil s.fetch(dkey, ext, *size), "a cut #{ext} was taken"
        File.binwrite(path, bytes)
        assert s.fetch(dkey, ext, *size), "a whole #{ext} wasn't taken"
      end
  end

  def test_the_source_memo_needs_the_same_file
    s = store
    path = File.join(@dir, "a.png")
    File.binwrite(path, png(2, 2))
    s.remember_source(path, File.stat(path), "sha512" => "abc")
    assert_equal "abc", s.source_info(path, File.stat(path))["sha512"]
    File.binwrite(path, png(2, 2, seed: 1))
    assert_nil s.source_info(path, File.stat(path))
  end

  def test_unreadable_files_are_ignored_with_a_warning
    FileUtils.mkdir_p(File.join(@dir, "v1"))
    File.write(File.join(@dir, "v1", "index.json"), "[1, 2")
    File.write(File.join(@dir, "v1", "pages.json"), "[]")
    warnings = []
    Jekyll.logger.stub(:warn, ->(*args) { warnings << args.join(" ") }) { store }
    assert_equal 1, warnings.size
    assert_includes warnings[0], "index.json, which can't be read"
  end

  def test_a_build_without_assets_writes_no_cache
    store.save(full_build: true, site_source: "/site", live_pages: Set.new)
    refute File.exist?(File.join(@dir, "v1"))
  end
end
