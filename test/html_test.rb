# frozen_string_literal: true

require_relative "test_helper"

# <img> markup must be byte-identical to jekyll-assets', which serialized it
# with Nokogiri: translated pages key their text by it.
class HtmlTest < Minitest::Test
  GOLDEN = JSON.parse(File.read(File.join(MagikTestHelper::FIXTURES, "nokogiri-img.json"), encoding: "UTF-8"))

  def test_golden_markup_from_beekeepers_nokogiri
    assert_equal "2.13.5", GOLDEN["libxml2"]
    GOLDEN["cases"].each do |c|
      assert_equal c["html"], Jekyll::Magik::Html.img(c["attributes"]), c["attributes"].inspect
    end
  end

  def test_nul_is_refused
    assert_raises(Jekyll::Magik::Error) { Jekyll::Magik::Html.img([["alt", "a\0b"]]) }
  end

  def test_attribute_names
    assert Jekyll::Magik::Html.valid_name?(:"data-turbo-track")
    assert Jekyll::Magik::Html.valid_name?(:"aria-label")
    assert Jekyll::Magik::Html.valid_name?(:"xml:lang")
    refute Jekyll::Magik::Html.valid_name?(:"a b")
    refute Jekyll::Magik::Html.valid_name?(:"a\"b")
    refute Jekyll::Magik::Html.valid_name?(:"1x")
    refute Jekyll::Magik::Html.valid_name?(:"")
  end

  # Random values against the Nokogiri in the bundle, when it serializes
  # with the same libxml2 series as the golden file.
  def test_random_values_against_live_nokogiri
    require "nokogiri"
    skip "needs libxml2 2.13" unless Nokogiri::VERSION_INFO.dig("libxml", "loaded").to_s.start_with?("2.13.")

    rng = Random.new(42)
    alphabet = ["a", " ", "&", "<", ">", "\"", "'", "\t", "\n", "\r", "\u0001", "\u007f", "é", " ", "😀",
                "%", "#", "=", ";", "amp;", "/"]
    2_000.times do
      attributes = Array.new(rng.rand(1..3)) do |i|
        name = %w(alt src href title class action ismap disabled)[rng.rand(8)] + (i.zero? ? "" : i.to_s)
        [name, Array.new(rng.rand(0..10)) { alphabet[rng.rand(alphabet.size)] }.join]
      end
      assert_equal nokogiri_img(attributes.to_h), Jekyll::Magik::Html.img(attributes), attributes.inspect
    end
  end

  def nokogiri_img(attributes)
    doc = Nokogiri::HTML.fragment("")
    Nokogiri::HTML::Builder.with(doc) { |html| html.img(attributes) }
    doc.to_html
  end
end
