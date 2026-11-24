# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  # String keys given without braces arrive as keywords in Ruby 3.
  def config(hash = {}, env: "development", **options)
    Jekyll::Magik::Config.new({ "source" => "/site" }.merge(hash).merge(options), env: env)
  end

  def test_defaults
    c = config
    assert_equal "assets", c.destination
    assert_nil c.baseurl
    refute c.img_integrity
    assert config(env: "production").img_integrity
    assert_equal "/site/.jekyll-cache/magik", c.cache_dir
    assert_equal [Etc.nprocessors - 1, 1].max, c.workers
    assert_equal 14, c.gc_max_age_days
    assert_equal 82, c.jpeg_quality
    assert_equal 75, c.webp_quality
    refute c.derivative_integrity
    refute c.manifest
    assert_empty c.warnings
  end

  def test_load_paths_are_the_sources_then_jekyll_assets_defaults
    c = config("assets" => { "sources" => ["_assets", "assets/css"] })
    assert_equal %w(_assets assets/css assets/fonts assets/images), c.sources.first(4)
    assert_equal %w(_assets/image _assets/img _assets/js), c.sources.last(3)
    assert_equal 37, c.sources.size
    assert_equal "/site/_assets", c.load_paths.first
    assert_equal c.load_paths.uniq, c.load_paths
  end

  def test_urls
    assert_equal "/assets/img/a.png", config.url_for("img/a.png")
    assert_equal "/blog/assets/img/a.png", config("baseurl" => "/blog").url_for("img/a.png")
    assert_equal "/blog/assets/img/a.png", config("baseurl" => "/blog/").url_for("img/a.png")
    assert_equal "/root/assets/a.png", config("baseurl" => "/blog", "baseurl_root" => "/root").url_for("a.png")
    assert_equal "/static/a.png", config("assets" => { "destination" => "/static/" }).url_for("a.png")
    assert_equal "/a.png", config("assets" => { "destination" => "" }).url_for("a.png")
    assert_equal "static/a.png", config("assets" => { "destination" => "static" }).dest_path_for("a.png")
  end

  def test_integrity_setting
    assert config("assets" => { "defaults" => { "img" => { "integrity" => true } } }).img_integrity
    refute config("assets" => { "defaults" => { "img" => { "integrity" => false } } }, env: "production").img_integrity
    assert config("assets" => { "defaults" => { "img" => {} } }, env: "production").img_integrity
  end

  def test_ignored_assets_keys_warn
    c = config("assets" => { "source_maps" => true, "compression" => true, "caching" => { "enabled" => false },
                             "defaults" => { "img" => { "integrity" => true, "alt" => "x" }, "js" => {} },
                             "digest" => true, "gzip" => false, "precompile" => [] })
    assert_equal [
      "`assets: source_maps` in _config.yml is ignored",
      "`assets: compression` in _config.yml is ignored",
      "`assets: caching` in _config.yml is ignored",
      "`assets: defaults: js` in _config.yml is ignored",
      "`assets: defaults: img: alt` in _config.yml is ignored"
    ].sort, c.warnings.sort
  end

  def test_assets_keys_that_would_change_output_raise
    [
      { "digest" => false }, { "digest_algorithm" => "sha256" }, { "full_url" => true },
      { "cdn" => { "url" => "https://cdn.example.com" } }, { "precompile" => ["fonts/*"] },
      { "raw_precompile" => ["x"] }, { "gzip" => true },
      { "responsive" => { "automatic" => true } }, { "responsive" => { "discovery" => true } },
      { "plugins" => { "img" => { "searcher" => true } } },
      { "defaults" => { "img" => { "width" => true } } }, { "defaults" => { "img" => { "height" => "auto" } } }
    ].each do |assets|
      error = assert_raises(Jekyll::Magik::NotSupported, assets.inspect) { config("assets" => assets) }
      assert_includes error.message, "isn't supported by jekyll-magik"
    end
    config("assets" => { "digest_algorithm" => "sha512", "cdn" => { "url" => nil },
                         "responsive" => { "automatic" => false }, "plugins" => { "img" => { "searcher" => false } } })
  end

  def test_magik_options
    c = config("magik" => { "cache_dir" => "tmp/magik", "workers" => 0, "gc" => { "max_age_days" => 3 },
                            "jpeg_quality" => 90, "webp_quality" => 60, "derivative_integrity" => true,
                            "manifest" => true, "colour" => "blue" })
    assert_equal "/site/tmp/magik", c.cache_dir
    assert_equal "tmp/magik", c.relative_cache_dir
    assert_equal 0, c.workers
    assert_equal 3, c.gc_max_age_days
    assert_equal [90, 60], [c.jpeg_quality, c.webp_quality]
    assert c.derivative_integrity
    assert c.manifest
    assert_equal ["unknown option `magik: colour` in _config.yml"], c.warnings
    assert_nil config("magik" => { "gc" => false }).gc_max_age_days
    assert_nil config("magik" => { "gc" => { "max_age_days" => false } }).gc_max_age_days
    assert_nil config("magik" => { "cache_dir" => "/elsewhere" }).relative_cache_dir
  end

  def test_bad_magik_options_raise
    [
      { "workers" => -1 }, { "workers" => "2" }, { "jpeg_quality" => 0 }, { "webp_quality" => 101 },
      { "gc" => 3 }, { "gc" => { "max_age_days" => 0 } }, { "derivative_integrity" => "yes" },
      { "cache_dir" => "" }
    ].each do |magik|
      assert_raises(Jekyll::Magik::ConfigError, magik.inspect) { config("magik" => magik) }
    end
    assert_raises(Jekyll::Magik::ConfigError) { config("magik" => "fast") }
    assert_raises(Jekyll::Magik::ConfigError) { config("assets" => ["_assets"]) }
  end

  def test_a_custom_cache_dir_inside_the_source_is_excluded
    dir = Dir.mktmpdir
    site = Jekyll::Site.new(Jekyll.configuration("source" => dir, "destination" => File.join(dir, "_site"),
                                                 "quiet" => true, "magik" => { "cache_dir" => "tmp/magik" }))
    assert_includes site.exclude, "tmp/magik"
  ensure
    FileUtils.rm_rf(dir)
  end
end
