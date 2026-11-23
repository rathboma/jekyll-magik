# frozen_string_literal: true

require_relative "test_helper"

class AssetFileTest < Minitest::Test
  include MagikTestHelper

  def setup
    @dir = fixture_copy
    @site = site_for(@dir)
    @site.reset
    @source = @site.magik.lookup("logo.png")
    @file = Jekyll::Magik::AssetFile.new(@site, @source)
    @dest = @file.destination(@site.dest)
  end

  def test_paths
    assert_equal File.join(@dir, "_site", @source.url), @dest
    assert_equal @source.url, @file.url
    assert_equal File.join(@dir, "_assets/img/logo.png"), @file.path
    assert_equal "_assets/img/logo.png", @file.relative_path
    assert_equal ".png", @file.extname
    assert @file.write?
  end

  def test_writes_a_copy_with_the_source_mtime
    assert @file.write(@site.dest)
    assert_equal File.binread(@file.path), File.binread(@dest)
    refute_equal File.stat(@file.path).ino, File.stat(@dest).ino
    assert_equal File.stat(@file.path).mtime, File.stat(@dest).mtime
    assert_empty Dir.glob(File.join(File.dirname(@dest), ".magik-*"))
  end

  def test_skips_a_destination_that_is_already_the_copy
    @file.write(@site.dest)
    inode = File.stat(@dest).ino
    refute @file.write(@site.dest)
    assert_equal inode, File.stat(@dest).ino
  end

  def test_replaces_rather_than_writes_in_place
    FileUtils.mkdir_p(File.dirname(@dest))
    File.write(@dest, "stale")
    other = "#{@dest}.other-link"
    File.link(@dest, other)
    assert @file.write(@site.dest)
    assert_equal File.binread(@file.path), File.binread(@dest)
    assert_equal "stale", File.read(other), "the old file was written in place"
  end

  def test_a_hardlink_to_the_source_is_replaced_by_a_copy
    FileUtils.mkdir_p(File.dirname(@dest))
    File.link(@file.path, @dest)
    assert @file.write(@site.dest)
    refute_equal File.stat(@file.path).ino, File.stat(@dest).ino
    File.write(@dest, "edited in _site")
    assert_equal File.binread(File.join(FIXTURE, "_assets/img/logo.png")), File.binread(@file.path)
  end
end
