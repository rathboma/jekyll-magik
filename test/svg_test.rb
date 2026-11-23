# frozen_string_literal: true

require_relative "test_helper"

class SvgTest < Minitest::Test
  def inline(markup, attributes = [])
    Jekyll::Magik::Svg.inline(markup, attributes, filename: "x.svg")
  end

  def test_the_markup_is_kept_byte_for_byte
    svg = %(<svg viewBox="0 0 1 1"\n\txmlns='http://www.w3.org/2000/svg' ><path d="M0 0"/><!-- c --></svg>)
    assert_equal svg, inline(svg)
    assert_equal svg, inline("#{svg}\n\n")
  end

  def test_the_prolog_and_doctype_are_dropped_and_comments_kept
    svg = <<~SVG
      ﻿<?xml version="1.0" encoding="utf-8"?>
      <!-- Generator: Adobe Illustrator -->
      <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [
        <!ENTITY ns_svg "http://www.w3.org/2000/svg">
      ]>
      <?xml-stylesheet href="a.css"?>
      <svg viewBox="0 0 1 1"></svg>
    SVG
    assert_equal %(<!-- Generator: Adobe Illustrator -->\n<svg viewBox="0 0 1 1"></svg>), inline(svg)
    assert_equal %(<svg/>), inline(%(<?xml version="1.0"?><svg/>))
  end

  def test_attributes_are_set_on_the_root_keeping_case_and_place
    svg = %(<svg id="a" viewBox="0 0 1 1" class='old'>\n<g class="inner"/></svg>)
    assert_equal %(<svg id="a" viewBox="0 0 1 1" class="hero">\n<g class="inner"/></svg>),
                 inline(svg, [[:class, "hero"]])
    assert_equal %(<svg id="a" viewBox="0 0 1 1" class='old' aria-label="A &amp; &quot;B&quot; &lt;c&gt;" width="300">\n<g class="inner"/></svg>),
                 inline(svg, [[:"aria-label", %(A & "B" <c>)], [:width, 300]])
    assert_equal %(<svg viewBox="0 0 2 2" class='old'>\n<g class="inner"/></svg>),
                 inline(%(<svg viewBox="0 0 1 1" class='old'>\n<g class="inner"/></svg>), [[:viewBox, "0 0 2 2"]])
    assert_equal %(<svg a="1" b="2"/>), inline(%(<svg a="1"/>), [[:b, 2]])
    assert_equal %(<svg b="x&#10;y"></svg>), inline(%(<svg></svg>), [[:b, "x\ny"]])
  end

  def test_not_an_svg
    [%(<html></html>), %(<svgfoo/>), %(text), %(<svg a=1></svg>), %(<!-- only a comment -->)].each do |markup|
      assert_raises(Jekyll::Magik::NotSupported, markup) { inline(markup) }
    end
    assert_raises(Jekyll::Magik::NotSupported) { inline("<svg>\xff</svg>".b) }
  end
end
