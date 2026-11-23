# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class WorkerTest < Minitest::Test
  include MagikTestHelper

  LIB = File.expand_path("../lib", __dir__)

  # CLAUDE.md, rule 5: Jekyll's process resizes through a worker and never
  # loads libvips itself.
  def test_jekyll_never_loads_libvips
    dir = fixture_copy
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", <<~RUBY, dir)
      require "jekyll"
      require "jekyll-magik"
      site = Jekyll::Site.new(Jekyll.configuration("source" => ARGV[0], "destination" => File.join(ARGV[0], "_site"),
                                                   "quiet" => true))
      site.process
      print site.magik.stats[:processed], " ", $LOADED_FEATURES.grep(/vips/).size
    RUBY
    assert status.success?, err
    assert_equal "8 0", out
  end

  # `workers: 0` runs the same pipeline in Jekyll's process.
  def test_in_process_mode_writes_the_same_bytes
    _, spawned = build
    _, in_process = build(config: { "magik" => { "workers" => 0 } })
    a = object_files(spawned)
    b = object_files(in_process)
    assert_equal 8, a.size
    assert_equal(a.map { |f| File.basename(f) }, b.map { |f| File.basename(f) })
    a.zip(b).each { |x, y| assert_equal File.binread(x), File.binread(y), File.basename(x) }
  end

  def fake_worker(code)
    dir = Dir.mktmpdir("magik-worker-")
    (@tmpdirs ||= []) << dir
    path = File.join(dir, "worker.rb")
    File.write(path, "require 'json'\n$stdout.sync = true\n#{code}")
    Jekyll::Magik::Processor.new(worker: path)
  end

  def test_a_worker_without_libvips_fails_with_install_instructions
    processor = fake_worker(%(puts JSON.generate("ready" => false, "error" => "cannot load vips.so.42"); exit 1))
    error = assert_raises(Jekyll::Magik::Error) { processor.run("id" => "x") }
    assert_includes error.message, "resizing images needs libvips 8.13 or newer"
    assert_includes error.message, "(cannot load vips.so.42)"
    assert_includes error.message, "libvips42t64"
    assert_nil processor.pid
    again = assert_raises(Jekyll::Magik::Error) { processor.run("id" => "y") }
    assert_same error, again
  end

  def test_a_worker_without_the_ruby_vips_gem_says_so
    processor = fake_worker(%(puts JSON.generate("ready" => false, "error" => "cannot load such file -- vips"); exit 1))
    error = assert_raises(Jekyll::Magik::Error) { processor.run("id" => "x") }
    assert_includes error.message, "resizing images needs the ruby-vips gem"
    assert_includes error.message, "`gem \"jekyll-magik\"` in your Gemfile"
  end

  def test_a_libvips_that_is_too_old_fails
    processor = fake_worker(%(puts JSON.generate("ready" => true, "vips" => "8.10.6"); $stdin.read))
    error = assert_raises(Jekyll::Magik::Error) { processor.run("id" => "x") }
    assert_includes error.message, "(found libvips 8.10.6)"
  end

  def test_a_worker_that_dies_fails_the_job_and_is_started_again_next_time
    processor = fake_worker(<<~RUBY)
      puts JSON.generate("ready" => true, "vips" => "8.15.1")
      job = JSON.parse($stdin.gets)
      exit 3 if job["id"] == "die"
      puts JSON.generate("id" => job["id"], "ok" => true)
    RUBY
    error = assert_raises(Jekyll::Magik::Error) { processor.run("id" => "die", "source" => "/a.png") }
    assert_match(/the image worker exited \(.*exit 3.*\) while processing \/a.png/, error.message)
    assert_equal({ "id" => "ok", "ok" => true }, processor.run("id" => "ok"))
    processor.stop
  end

  def test_a_reply_that_isnt_json_fails
    processor = fake_worker(%(puts JSON.generate("ready" => true, "vips" => "8.15.1"); $stdin.gets; puts "oops"))
    error = assert_raises(Jekyll::Magik::Error) { processor.run("id" => "x") }
    assert_equal "the image worker replied with something that isn't JSON: oops", error.message
  end

  def test_the_real_worker_reports_errors_per_job_and_keeps_going
    processor = Jekyll::Magik::Processor.new
    reply = processor.run("id" => "a", "source" => "/nope.png")
    assert_equal false, reply["ok"]
    assert_includes reply["error"], "/nope.png"
    reply = processor.run("not json")
    assert_equal false, reply["ok"]
    assert_match(/\A8\.\d+/, processor.vips_version)
  ensure
    processor&.stop
  end
end
