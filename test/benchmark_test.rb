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
end
