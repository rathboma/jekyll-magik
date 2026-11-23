# frozen_string_literal: true

require_relative "test_helper"

# Sprockets 4's lookup rules, as jekyll-assets used them. The expectations
# come from running the same names through sprockets (see bench/originals for
# the check against beekeeper-studio/web).
class ResolverTest < Minitest::Test
  include MagikTestHelper

  def setup
    @dir = Dir.mktmpdir("magik-resolver-")
    files = %w(
      _assets/img/a.jpeg _assets/img/b.tiff _assets/img/c.m4v _assets/img/d.jpg
      _assets/img/home/e.png _assets/img/home/e.jpg _assets/img/home/e.svg
      _assets/img/blog/q3/chart.png _assets/img/blog/q3/chart.gif
      _assets/img/f.jpeg _assets/img/f.jpg _assets/img/g.min.png _assets/img/v1.0/h.png
      _assets/img/release-1.0.png _assets/img/dir/index.png _assets/img/dir.png
      _assets/img/.hidden.png _assets/img/#temp.png# _assets/img/backup.png~
      _assets/img/both.png _assets/both.png _assets/fonts/x.woff2
      _assets/img/noext _assets/img/odd.psd
      assets/images/legacy.png img/root.png _assets/images/later.png
      custom/first.png custom/img/z.png _assets/img/z.png
    )
    files.each do |f|
      path = File.join(@dir, f)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, f)
    end
    FileUtils.mkdir_p(File.join(@dir, "_assets/img/home/sub.png"))
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def resolver(sources = ["_assets"])
    config = Jekyll::Magik::Config.new({ "source" => @dir, "assets" => { "sources" => sources } })
    Jekyll::Magik::Resolver.new(config)
  end

  def find(name, sources = ["_assets"])
    source = resolver(sources).find(name)
    source && [source.logical_path, source.filename.delete_prefix("#{@dir}/"), source.content_type]
  end

  def test_exact_and_nested_names
    assert_equal ["img/d.jpg", "_assets/img/d.jpg", "image/jpeg"], find("d.jpg")
    assert_equal ["img/d.jpg", "_assets/img/d.jpg", "image/jpeg"], find("img/d.jpg")
    assert_equal ["img/home/e.png", "_assets/img/home/e.png", "image/png"], find("home/e.png")
    assert_equal ["fonts/x.woff2", "_assets/fonts/x.woff2", "application/font-woff2"], find("x.woff2")
  end

  def test_extensions_match_by_type
    assert_equal "img/a.jpeg", find("a.jpg")[0]
    assert_equal "img/d.jpg", find("d.jpeg")[0]
    assert_equal "img/b.tiff", find("b.tif")[0]
    assert_equal "img/c.m4v", find("c.mp4")[0]
    # Both exist: the first in sorted order of the type.
    assert_equal "img/f.jpeg", find("f.jpg")[0]
    assert_equal "img/f.jpeg", find("f.jpeg")[0]
  end

  def test_names_without_an_extension_take_the_first_sorted_match
    assert_equal "img/home/e.jpg", find("home/e")[0]
    assert_equal "img/blog/q3/chart.gif", find("blog/q3/chart")[0]
    assert_equal "img/blog/q3/chart.gif", find("img/blog/q3/chart")[0]
    assert_equal "img/release-1.0.png", find("release-1.0")[0]
    assert_equal "img/g.min.png", find("g.min")[0]
    assert_equal "img/v1.0/h.png", find("v1.0/h")[0]
  end

  def test_a_directory_index_comes_after_files
    assert_equal "img/dir.png", find("dir")[0]
    assert_equal "img/dir/index.png", find("dir/index")[0]
    assert_equal "img/dir/index.png", find("dir/index.png")[0]
  end

  def test_directories_and_hidden_backup_and_unregistered_files_are_skipped
    assert_nil find(".hidden.png")
    assert_nil find("#temp.png#")
    assert_nil find("backup")
    assert_nil find("home/sub.png")
    assert_nil find("odd")
    error = assert_raises(Jekyll::Magik::NotSupported) { find("odd.psd") }
    assert_includes error.message, "unregistered extension"
    error = assert_raises(Jekyll::Magik::NotSupported) { find("noext") }
    assert_includes error.message, "unregistered extension"
  end

  def test_load_path_order_and_the_logical_path
    # _assets comes before _assets/img, so the logical path keeps img/.
    assert_equal "img/both.png", find("img/both.png")[0]
    assert_equal ["both.png", "_assets/both.png", "image/png"], find("both.png")
    # jekyll-assets' default directories are load paths too.
    assert_equal ["legacy.png", "assets/images/legacy.png", "image/png"], find("legacy.png")
    assert_equal ["root.png", "img/root.png", "image/png"], find("root.png")
    assert_equal ["images/later.png", "_assets/images/later.png", "image/png"], find("later.png")
  end

  def test_configured_sources_come_first
    assert_equal ["z.png", "custom/img/z.png", "image/png"], find("z.png", %w(custom/img _assets))
    assert_equal ["z.png", "custom/img/z.png", "image/png"], find("z.png", %w(_assets custom/img))
    assert_equal ["img/z.png", "_assets/img/z.png", "image/png"], find("img/z.png", %w(_assets custom/img))
    assert_equal ["z.png", "_assets/img/z.png", "image/png"], find("z.png", %w(_assets/img custom/img))
    assert_equal ["first.png", "custom/first.png", "image/png"], find("first.png", %w(custom))
    assert_nil find("first.png")
  end

  def test_invalid_names_are_unknown
    ["", "/img/d.jpg", "./d.jpg", "../_assets/img/d.jpg", "img//d.jpg", "img/./d.jpg", "img/../img/d.jpg",
     "d.jpg/", "nope.png", "img/nope"].each do |name|
      assert_nil find(name), name
    end
  end

  def test_results_and_sources_are_memoized_for_the_build
    r = resolver
    assert_same r.find("home/e"), r.find("home/e.jpg")
    assert_same r.find("d.jpg"), r.find("img/d.jpg")
    File.write(File.join(@dir, "_assets/img/new.png"), "x")
    assert_nil r.find("nope.png")
    # A directory is listed once per build, so a file added mid-build waits
    # for the next one.
    assert_nil r.find("new.png")
    refute_nil resolver.find("new.png")
  end

  def test_digest_path_and_url
    source = resolver.find("home/e")
    digest = Digest::SHA512.hexdigest("_assets/img/home/e.jpg")
    assert_equal "img/home/e-#{digest}.jpg", source.digest_path
    assert_equal "/assets/img/home/e-#{digest}.jpg", source.url
    assert_equal "assets/img/home/e-#{digest}.jpg", source.dest_path
    assert_equal "sha512-#{[Digest::SHA512.digest("_assets/img/home/e.jpg")].pack("m0")}", source.integrity
  end
end
