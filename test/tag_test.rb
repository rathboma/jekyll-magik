# frozen_string_literal: true

require_relative "test_helper"

class TagTest < Minitest::Test
  include MagikTestHelper

  def logo_url
    @logo_url ||= fixture_site.magik.lookup("logo.png").url
  end

  def test_attributes_in_tag_order_then_src_integrity_crossorigin
    out = render(%({% asset logo.png title="T" alt="A" class="c" width=10 height="20" loading="lazy" style="x: y" %}))
    assert_match(/\A<img title="T" alt="A" class="c" width="10" height="20" loading="lazy" style="x: y" src="#{logo_url}" integrity="sha512-[^"]+" crossorigin="anonymous">\z/o, out)
  end

  def test_numbers_are_written_as_jekyll_assets_wrote_them
    assert_includes render(%({% asset logo.png width=10 height=1.50 %})), %(width="10" height="1.5")
  end

  def test_given_src_integrity_or_crossorigin_keep_their_place_as_in_jekyll_assets
    assert_match(/\A<img src="#{logo_url}" alt="a" integrity="[^"]+" crossorigin="anonymous">\z/o,
                 render(%({% asset logo.png src="x" alt="a" %})))
    assert_equal %(<img integrity="mine" src="#{logo_url}">), render(%({% asset logo.png integrity="mine" %}))
    assert_match(/\A<img crossorigin="use-credentials" src="[^"]+" integrity="[^"]+">\z/,
                 render(%({% asset logo.png crossorigin="use-credentials" %})))
  end

  def test_path_ignores_attributes_like_jekyll_assets
    assert_equal logo_url, render(%({% asset logo.png alt="x" @path %}))
    assert_equal logo_url, render(%({% asset logo.png @path alt="x" %}))
  end

  def test_liquid_is_rendered_in_every_value
    out = render(%({% asset {{page.n}}.png alt="{{ page.alt | upcase }} & co" %}), assigns: { "n" => "logo", "alt" => "a" })
    assert_match(/\A<img alt="A &amp; co" src="#{logo_url}"/o, out)
  end

  def test_liquid_values_are_rendered_on_every_call
    template = Liquid::Template.parse(%({% for n in page.names %}{% asset {{n}} @path %} {% endfor %}))
    page = { "path" => "x.html", "names" => %w(logo.png anim.gif logo) }
    out = template.render!({ "page" => page }, registers: { site: fixture_site, page: page })
    gif = fixture_site.magik.lookup("anim.gif").url
    assert_equal "#{logo_url} #{gif} #{logo_url} ", out
  end

  def test_tags_are_parsed_once
    calls = 0
    original = Jekyll::Magik::Args.method(:parse)
    Jekyll::Magik::Args.define_singleton_method(:parse) do |raw|
      calls += 1
      original.call(raw)
    end
    template = Liquid::Template.parse(%({% for i in (1..5) %}{% asset logo.png @path %}{% endfor %}))
    page = { "path" => "x.html" }
    3.times { template.render!({ "page" => page }, registers: { site: fixture_site, page: page }) }
    assert_equal 1, calls
  ensure
    Jekyll::Magik::Args.define_singleton_method(:parse, original)
  end

  def test_integrity_off
    site = site_for(FIXTURE, "destination" => Dir.mktmpdir,
                             "assets" => { "sources" => ["_assets"], "defaults" => { "img" => { "integrity" => false } } })
    assert_equal %(<img alt="a" src="#{logo_url}">), render(%({% asset logo.png alt="a" %}), site: site)
  end

  def test_rendering_marks_the_asset_used_and_records_the_dependency
    site = site_for(fixture_copy)
    site.reset
    render(%({% asset logo.png %}{% asset logo.png @path %}), site: site, path: "about.md")
    assert_equal ["img/logo.png"], site.magik.used.map(&:logical_path)
    assert_equal(1, site.static_files.count { |f| f.is_a?(Jekyll::Magik::AssetFile) })
  end

  def test_a_tag_that_raises_marks_nothing_used
    site = site_for(fixture_copy)
    site.reset
    assert_raises(Jekyll::Magik::NotSupported) { render(%({% asset clip.mp4 %}), site: site) }
    assert_raises(Jekyll::Magik::NotSupported) { render(%({% asset logo.png @inline %}), site: site) }
    assert_empty site.magik.used
    assert_empty site.static_files.grep(Jekyll::Magik::AssetFile)
  end

  def test_dependencies_of_tags_filters_and_collection_documents
    dir = fixture_copy("my_collections/_posts/2020-01-01-a.md" => "---\n---\n")
    site = site_for(dir, "incremental" => true, "collections_dir" => "my_collections")
    site.reset
    page = File.join(dir, "index.html")
    doc = File.join(dir, "my_collections/_posts/2020-01-01-a.md")
    [page, doc].each { |p| site.regenerator.add(p) }
    render(%({{ "photo.jpg" | asset_size | join: "x" }}), site: site)
    render(%({% asset logo.png @path %}), site: site, path: "_posts/2020-01-01-a.md",
                                          assigns: { "collection" => "posts" })
    assert_includes site.regenerator.metadata[page]["deps"], File.join(dir, "_assets/img/photo.jpg")
    assert_includes site.regenerator.metadata[doc]["deps"], File.join(dir, "_assets/img/logo.png")
  end

  def test_a_url_outside_the_digest_grammar_warns
    dir = fixture_copy("_assets/img/sp ace.png" => "x")
    site = site_for(dir)
    site.reset
    warnings = []
    Jekyll.logger.stub(:warn, ->(*args) { warnings << args.join(" ") }) do
      render(%({% asset 'sp ace.png' @path %}{% asset logo.png @path %}), site: site)
    end
    assert_equal 1, warnings.size
    assert_includes warnings[0], "/assets/img/sp ace-"
  end

  def test_regenerator_dependency
    dir = fixture_copy
    site = site_for(dir, "incremental" => true)
    site.reset
    page = File.join(dir, "index.html")
    site.regenerator.add(page)
    render(%({% asset logo.png %}), site: site)
    assert_includes site.regenerator.metadata[page]["deps"], File.join(dir, "_assets/img/logo.png")
  end

  def test_unknown_assets
    {
      %({% asset nope.png %}) => "Unknown asset 'nope.png' in index.html ({% asset nope.png %})",
      %({% asset %}) => "Unknown asset '' in index.html ({% asset  %})",
      %({% asset '' %}) => "Unknown asset '' in index.html ({% asset '' %})",
      %({% asset /img/logo.png %}) => "Unknown asset '/img/logo.png' in index.html ({% asset /img/logo.png %})",
      %({% asset ../_assets/img/logo.png %}) => "Unknown asset '../_assets/img/logo.png' in index.html",
      %({% asset img//logo.png %}) => "Unknown asset 'img//logo.png' in index.html"
    }.each do |tag, message|
      error = assert_raises(Jekyll::Magik::UnknownAsset, tag) { render(tag) }
      assert error.message.start_with?(message), "#{tag}: #{error.message}"
    end
  end

  # Everything outside the scope table in #1 raises, naming the page and the
  # tag, rather than doing something other than what jekyll-assets did.
  def test_out_of_scope_raises
    {
      %({% asset logo.png @data %}) => "`@data` (data URIs) isn't supported",
      %({% asset logo.png @pic %}) => "`@pic` isn't supported",
      %({% asset logo.png @lazy %}) => "`@lazy` isn't supported",
      %({% asset logo.png !path %}) => "`!path` isn't supported",
      %({% asset logo.png lazy %}) => "`lazy` without a value isn't supported",
      %({% asset logo.png alt=a alt=b %}) => "`alt` given more than once isn't supported",
      %({% asset logo.png magick:resize=10x %}) => "resizing with `magick:` isn't supported yet",
      %({% asset logo.png vips:resize=10 %}) => "`vips:` arguments aren't supported",
      %({% asset logo.png srcset:width=10 %}) => "`srcset:` isn't supported",
      %({% asset logo.png responsive:automatic=true %}) => "`responsive:` isn't supported",
      %({% asset logo.png foo:bar=1 %}) => "`foo:` arguments aren't supported",
      %({% asset logo.png path=yes %}) => "`path=` with a value isn't supported",
      %({% asset logo.png @path @inline %}) => "`@path` and `@inline` can't be used together",
      %({% asset hero.svg @inline @path %}) => "`@path` and `@inline` can't be used together",
      %({% asset logo.png a"b=1 %}) => "can't parse the arguments",
      %({% asset logo.png "unclosed %}) => "can't parse the arguments",
      %({% asset 404 %}) => "can't parse the arguments",
      %({% asset main.css %}) => "stylesheets (.css) aren't supported",
      %({% asset main.scss %}) => "stylesheets (.scss) aren't supported",
      %({% asset main %}) => "stylesheets (.scss) aren't supported",
      %({% asset app.js %}) => "scripts (.js) aren't supported",
      %({% asset hero.liquid.svg %}) => "Liquid assets (.liquid.svg) aren't supported",
      %({% asset notes.txt %}) => ".txt assets (text/plain) aren't supported",
      %({% asset main.css.debug %}) => "sprockets pipelines (.debug) aren't supported",
      %({% asset https://example.com/a.png %}) => "external URLs aren't supported",
      %({% asset //example.com/a.png %}) => "external URLs aren't supported",
      %({% asset logo.png @inline %}) => "`@inline` only supports SVG files",
      %({% asset clip.mp4 %}) => "video/mp4 assets can only be used with `@path`",
      %({% asset clip.mp4 @inline %}) => "`@inline` only supports SVG files"
    }.each do |tag, message|
      error = assert_raises(Jekyll::Magik::Error, tag) { render(tag) }
      assert_includes error.message, message, tag
      assert_includes error.message, " in index.html ({% asset #{tag[/\{% asset (.*) %\}/, 1]} %})", tag
    end
  end

  def test_the_asset_filter_is_not_supported
    error = assert_raises(Jekyll::Magik::NotSupported) { render(%({{ "logo.png" | asset }})) }
    assert_includes error.message, "the `asset` filter isn't supported"
  end

  def test_asset_url_filter
    assert_equal logo_url, render(%({{ "logo.png" | asset_url }}))
    assert_equal "", render(%({{ "" | asset_url }}{{ nil | asset_url }}))
    error = assert_raises(Jekyll::Magik::UnknownAsset) { render(%({{ "nope.png" | asset_url }})) }
    assert_equal "Unknown asset 'nope.png' in index.html", error.message
  end

  def test_asset_size_filter_doesnt_mark_the_asset_used
    site = site_for(fixture_copy)
    site.reset
    sizes = %w(logo.png home/edit-schema hero.svg).map { |n| %({{ "#{n}" | asset_size | join: "," }}) }
    assert_equal "12,8 4,3 40,20", render(sizes.join(" "), site: site)
    assert_empty site.magik.used
    assert_raises(Jekyll::Magik::UnknownAsset) { render(%({{ "nope.png" | asset_size }}), site: site) }
    error = assert_raises(Jekyll::Magik::NotSupported) { render(%({{ "clip.mp4" | asset_size }}), site: site) }
    assert_includes error.message, "isn't an image"
  end

  def test_the_ruby_api
    site = site_for(fixture_copy)
    site.reset
    asset = site.magik.find!("blog/default.jpg")
    assert_equal "img/blog/default.jpg", asset.logical_path
    assert_equal File.join(site.source, "_assets/img/blog/default.jpg"), asset.filename
    assert_match(%r{\A/assets/img/blog/default-\h{128}\.jpg\z}, asset.url)
    assert_match(/\Asha512-[A-Za-z0-9+\/]{86}==\z/, asset.integrity)
    assert_equal [5, 5], [asset.width, asset.height]
    assert_equal asset.url, site.magik.url("img/blog/default.jpg")
    assert_equal ["img/blog/default.jpg"], site.magik.used.map(&:logical_path)
  end
end
