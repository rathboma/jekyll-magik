# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "minitest/mock"
require "fileutils"
require "json"
require "tmpdir"
require "zlib"
require "jekyll"
require "jekyll-magik"

Jekyll.logger.log_level = :error

module MagikTestHelper
  FIXTURE = File.expand_path("fixtures/site", __dir__)
  FIXTURES = File.expand_path("fixtures", __dir__)

  # Copied from beekeeper-studio/web, workers/translate/src/assets.ts
  # (DIGESTED). Every asset URL jekyll-magik writes must match it, with a stem
  # that doesn't depend on the file's content.
  DIGESTED = %r{/assets/[\w./-]+?-(?:[0-9a-f]{64,128}|[0-9A-Z]{8})\.[a-z0-9]+}

  HEX128 = /\h{128}/

  # A derivative's URL: /assets/<logical path minus ext>-<tkey>-<dkey>.<ext>
  DERIVATIVE = %r{\A/assets/(.+)-(\h{10})-(\h{64})\.([a-z0-9]+)\z}

  # A copy of the fixture site in a temp dir, with extra or replaced files.
  def fixture_copy(files = {})
    dir = Dir.mktmpdir("magik-site-")
    FileUtils.cp_r("#{FIXTURE}/.", dir)
    files.each do |path, content|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      content.nil? ? FileUtils.rm_f(full) : File.write(full, content)
    end
    @tmpdirs ||= []
    @tmpdirs << dir
    dir
  end

  def site_for(dir, overrides = {})
    config = Jekyll.configuration(
      { "source" => dir, "destination" => File.join(dir, "_site"), "quiet" => true }.merge(overrides)
    )
    Jekyll::Site.new(config)
  end

  # Builds a copy of the fixture site; returns [site, dir].
  def build(files: {}, config: {})
    dir = fixture_copy(files)
    site = site_for(dir, config)
    site.process
    [site, dir]
  end

  def read_output(dir, path = "index.html")
    File.read(File.join(dir, "_site", path))
  end

  # The inner HTML of the element with that id in a fixture page.
  def element(html, id)
    html[%r{<(p|div) id="#{id}">(.*?)</\1>}m, 2].strip
  end

  # Renders Liquid in a site (by default the fixture, which isn't written to)
  # as a page at `path`.
  def render(template, site: fixture_site, path: "index.html", assigns: {})
    page = { "path" => path, "relative_path" => path }.merge(assigns)
    Liquid::Template.parse(template).render!(
      { "page" => page, "site" => site.site_payload["site"] },
      registers: { site: site, page: page }
    )
  end

  # The fixture itself, for rendering. Its caches go to a temp dir, so tests
  # never write into the repository.
  def fixture_site
    @fixture_site ||= begin
      tmp = Dir.mktmpdir("magik-fixture-")
      (@tmpdirs ||= []) << tmp
      site = site_for(FIXTURE, "destination" => File.join(tmp, "_site"), "disable_disk_cache" => true,
                               "magik" => { "cache_dir" => File.join(tmp, "cache") })
      site.reset
      site
    end
  end

  # A real PNG of that size, its pixels from `seed`, so that different seeds
  # give different files.
  def png(width, height, seed: 0)
    row = (0...width).map { |x| [((x * 7) + seed) % 256, (seed * 13) % 256, (x + (seed * 3)) % 256] }.flatten.pack("C*")
    raw = ("\0#{row}" * height).b
    chunk = lambda do |type, data|
      [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
    end
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) + chunk.call("IEND", "")
  end

  # [logical path minus ext, tkey, dkey, ext] of a derivative URL.
  def derivative_parts(url)
    m = DERIVATIVE.match(url)
    assert m, "#{url} isn't a derivative URL"
    m.captures
  end

  def object_files(dir, cache = ".jekyll-cache/magik")
    Dir.glob(File.join(dir, cache, "v1/objects/*/*"))
  end

  def sha512(path)
    Digest::SHA512.file(path).hexdigest
  end

  def teardown
    (@tmpdirs || []).each { |d| FileUtils.rm_rf(d) }
    super
  end
end
