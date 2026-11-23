# frozen_string_literal: true

require_relative "test_helper"
require "forwardable"
require "shellwords"
require "liquid/tag/parser"

# Jekyll::Magik::Args must read every tag the way liquid-tag-parser 2.0.2
# (jekyll-assets' parser) does: same hash, or an error for both.
class ArgsParityTest < Minitest::Test
  # Tricky markups, beyond what beekeeper-studio/web uses.
  SYNTHETIC = [
    "", " ", "a.png", "a.png ", "  a.png  alt=x", "a.png alt=\"x y\"", "a.png alt='x y'",
    %(a.png alt="it's" title='say "hi"'), %(a.png alt="a=b" title=c=d), "a.png alt=a\\=b",
    "a.png @path", "@path a.png", "!path a.png", "a.png !path", "a.png @magick:strip",
    "a.png magick:resize=600x magick:crop=600x300+0+0 magick:gravity=center",
    "a.png magick:resize='{{n}}x' magick:quality='80'", "a.png width=300 height=1.5 x=01 y=1.",
    "a.png width=\"300\"", "a.png alt=a alt=b alt=c", "a.png alt=a @alt", "a.png @alt alt=a", "a.png !alt alt=b",
    "a.png magick=x magick:resize=1", "a.png magick:resize=1 magick=x", "a.png @magick magick:resize=1",
    "a.png a:b:c=1 a:b:d=2", "a.png a:b=1 a:b:c=2", "a.png a\\:b=c", "a.png a\\\\:b=c", "a.png \\@x",
    "a.png @x\\:y", "a.png http://example.com/a.png", "https://example.com/a.png alt=x",
    "a.png data-turbo-track=\"reload\"", "a.png :x=1", "a.png x:=1", "a.png =x", "a.png x=", "a.png x==y",
    "a.png bare words here", "404", "1.5", "404.png", "a.png n=12\nab", "a.png \"unclosed",
    "a.png 'unclosed", "a.png x=\"a\\\"b\"", "a.png x='a\\'b'", "{{page.hero}} @inline",
    "{{ page.hero }} @inline", "'{{ include.asset }}' class=\"x\" alt=\"{{ include.alt | default: 'y' }}\"",
    "a.png alt=\"{{ post.title | escape }}\" @path", "a.png @@x", "a.png !!x", "a.png @x!", "a.png @-x",
    "a.png -x=1", "a.png x.y=1", "a.png é=1", "é.png alt=ü", "a.png alt=\"\"", "a.png \"\" x",
    "\"\" alt=x", "a\\ b.png", "\"a b.png\" alt=x", "a.png x=1 x=2 x=3 x:y=4"
  ].freeze

  def reference(markup)
    Liquid::Tag::Parser.new(markup).to_h
  rescue StandardError => e
    [:error, e.class]
  end

  def ours(markup)
    Jekyll::Magik::Args.parse(markup)
  rescue Jekyll::Magik::Args::ParseError => e
    [:error, e.class]
  end

  def assert_parity(markup, label = markup)
    expected = reference(markup)
    actual = ours(markup)
    if expected.is_a?(Array) && expected[0] == :error
      assert actual.is_a?(Array) && actual[0] == :error,
             "#{label.inspect}: liquid-tag-parser raised #{expected[1]}, ours gave #{actual.inspect}"
    else
      assert_equal expected, actual, label.inspect
    end
  end

  def test_every_tag_in_beekeeper_studio_web
    tags = JSON.parse(File.read(File.join(MagikTestHelper::FIXTURES, "beekeeper-tags.json"), encoding: "UTF-8"))
    assert_operator tags.size, :>=, 364
    tags.each { |t| assert_parity(t["markup"], "#{t["file"]}: #{t["markup"]}") }
  end

  def test_synthetic_corpus
    SYNTHETIC.each { |markup| assert_parity(markup) }
  end

  def test_random_markups
    rng = Random.new(20_261_123)
    pieces = ["a", "b", "png", "x.png", "alt", "magick", "resize", "1", "12", "1.5", "=", "=", ":", "@", "!",
              "\\", "\"", "'", " ", " ", " ", ".", "-", "/", "{{", "}}", "x"]
    5_000.times do
      markup = Array.new(rng.rand(0..12)) { pieces[rng.rand(pieces.size)] }.join
      assert_parity(markup)
    end
  end
end
