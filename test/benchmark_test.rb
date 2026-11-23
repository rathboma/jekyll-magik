# frozen_string_literal: true

require_relative "test_helper"

# Issue #1: rendering 5,000 tags of the kinds beekeeper-studio/web uses costs
# under 2s in total, image processing aside. (jekyll-assets spent ~19s of
# sprockets overhead on beekeeper's 5,393 tag renders.)
class BenchmarkTest < Minitest::Test
  include MagikTestHelper

  TAGS = [
    %({% asset photo.jpg alt="A photo" %}),
    %({% asset {{include.src}} @path %}),
    %({% asset '{{ include.src }}' class="lightbox-img" alt="{{ include.alt | default: include.description }}" %}),
    %({% asset blog/default.jpg alt="{{ post.title }}" loading="lazy" %}),
    %({% asset screenshots/main-dark %}),
    %({% asset logos/bk-logo-yellow-icon.svg height=42 class="logo-img" alt="Beekeeper Studio" %}),
    %({% asset videos/clip.mp4 @path %}),
    %({% asset {{include.svg}} @inline %})
  ].freeze

  def test_rendering_5000_tags
    dir = fixture_copy(
      "_assets/img/screenshots/main-dark.png" => File.binread(File.join(FIXTURE, "_assets/img/logo.png")),
      "_assets/img/logos/bk-logo-yellow-icon.svg" => File.read(File.join(FIXTURE, "_assets/img/hero.svg"))
    )
    site = site_for(dir)
    site.reset
    template = Liquid::Template.parse("{% for i in (1..625) %}#{TAGS.join("\n")}{% endfor %}")
    page = { "path" => "index.html", "relative_path" => "index.html" }
    assigns = { "page" => page, "post" => { "title" => "A & B" },
                "include" => { "src" => "blog/default.jpg", "description" => "D", "svg" => "hero.svg" } }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = template.render!(assigns, registers: { site: site, page: page })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 5_000, out.scan(/<img |\A\/assets|\n\/assets|<svg /).size
    puts format("\n  5,000 tags rendered in %.3fs", elapsed) if ENV["VERBOSE"]
    assert_operator elapsed, :<, 2.0
  end

  # Writes a PNG of the expected size where the worker would have written
  # the object, so the benchmark measures lookups, not libvips.
  class FakeProcessor
    include MagikTestHelper

    def run(job)
      width, height = job["steps"].last.last(2)
      FileUtils.mkdir_p(File.dirname(job["output"]))
      File.binwrite(job["output"], png(width, height))
      { "ok" => true, "width" => width, "height" => height, "bytes" => File.size(job["output"]) }
    end
  end

  # Issue #2: 2,180 derivative references, 591 of them unique, all cached,
  # in under 0.5s (beekeeper-studio/web's numbers; jekyll-assets spent ~17s
  # of sprockets overhead on them with a warm cache).
  def test_resolving_2180_cached_derivative_references
    files = (0...197).to_h { |i| ["_assets/img/bench/#{i}.png", png(40, 30, seed: i)] }
    dir = fixture_copy(files)
    unique = (0...197).flat_map { |i| [8, 16, 24].map { |w| ["bench/#{i}.png", w] } }
    page = { "path" => "index.html", "relative_path" => "index.html",
             "refs" => (0...2_180).map { |i| unique[i % unique.size] } }
    template = Liquid::Template.parse(
      "{% for r in page.refs %}{% asset {{r[0]}} magick:resize='{{r[1]}}x' magick:format='webp' " \
      "magick:quality='80' @magick:strip @path %}\n{% endfor %}"
    )

    site = site_for(dir)
    site.reset
    site.magik.processor = FakeProcessor.new
    template.render!({ "page" => page }, registers: { site: site, page: page })
    assert_equal 591, site.magik.stats[:processed]
    site.magik.store.save(full_build: false, site_source: dir)

    # A new process: the Store and the source memo come from disk.
    site = site_for(dir)
    site.reset
    site.magik.processor = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = template.render!({ "page" => page }, registers: { site: site, page: page })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal({ references: 2_180, derivatives: 591, cached: 591, processed: 0 },
                 site.magik.stats.slice(:references, :derivatives, :cached, :processed))
    assert_equal 591, out.split.uniq.size
    puts format("\n  2,180 cached derivative references resolved in %.3fs", elapsed) if ENV["VERBOSE"]
    assert_operator elapsed, :<, 0.5
  end
end
