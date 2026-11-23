# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class ConflictTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def run_ruby(code)
    Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", code)
  end

  def test_refuses_to_load_after_jekyll_assets
    _, err, status = run_ruby(<<~RUBY)
      require "jekyll"
      module Jekyll; module Assets; end; end
      require "jekyll-magik"
    RUBY
    refute status.success?
    assert_includes err, "jekyll-magik can't be used with jekyll-assets"
  end

  def test_refuses_to_build_when_jekyll_assets_loads_later
    _, err, status = run_ruby(<<~RUBY)
      require "jekyll"
      require "jekyll-magik"
      Liquid::Template.register_tag("asset", Class.new(Liquid::Tag))
      Jekyll::Site.new(Jekyll.configuration("source" => Dir.pwd, "quiet" => true))
    RUBY
    refute status.success?
    assert_includes err, "jekyll-magik's {% asset %} tag was replaced"
  end

  def test_loads_alone
    out, err, status = run_ruby(<<~RUBY)
      require "jekyll"
      require "jekyll-magik"
      print Liquid::Template.tags["asset"]
    RUBY
    assert status.success?, err
    assert_equal "Jekyll::Magik::Tag", out
  end
end
