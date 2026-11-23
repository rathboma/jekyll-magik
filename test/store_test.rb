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

  def test_only_full_builds_prune_this_sites_memo_and_pages
    s = store
    stat = File.stat(__FILE__)
    s.remember_source("/site/_assets/old.png", stat, "sha512" => "x")
    s.remember_source("/other/_assets/a.png", stat, "sha512" => "y")
    s.update_page("/site/gone.html", [])
    s.update_page("/other/page.html", [])
    s.save(full_build: false, site_source: "/site")

    s = store
    s.update_page("/site/index.html", [])
    s.save(full_build: false, site_source: "/site", live_pages: Set["/site/index.html"])
    assert_equal 2, saved("sources.json").size
    assert_equal 3, saved("pages.json").size

    s.save(full_build: true, site_source: "/site", live_pages: Set["/site/index.html"])
    assert_equal ["/other/_assets/a.png"], saved("sources.json").keys
    assert_equal %w(/other/page.html /site/index.html), saved("pages.json").keys
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
