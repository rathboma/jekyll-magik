# frozen_string_literal: true

require_relative "test_helper"
require "base64"

class WorkerTest < Minitest::Test
  include MagikTestHelper

  # CLAUDE.md, rule 5: Jekyll's process resizes through a worker and never
  # loads libvips itself.
  def test_jekyll_never_loads_libvips
    out = ruby_subprocess(<<~RUBY, fixture_copy)
      require "jekyll"
      require "jekyll-magik"
      site = Jekyll::Site.new(Jekyll.configuration("source" => ARGV[0], "destination" => File.join(ARGV[0], "_site"),
                                                   "quiet" => true))
      site.process
      print site.magik.stats[:processed], " ", $LOADED_FEATURES.grep(/vips/).size
    RUBY
    assert_equal "8 0", out
  end

  BUILD_IN_PROCESS = <<~RUBY
    require "jekyll"
    require "jekyll-magik"
    site = Jekyll::Site.new(Jekyll.configuration("source" => ARGV[0], "destination" => File.join(ARGV[0], "_site"),
                                                 "quiet" => true, "magik" => { "workers" => 0 }))
    site.process
    print site.magik.stats[:processed], " ", defined?(Vips) ? "vips" : "no vips"
  RUBY

  # `workers: 0` runs the same pipeline in Jekyll's process.
  def test_in_process_mode_writes_the_same_bytes
    _, spawned = build
    in_process = fixture_copy
    assert_equal "8 vips", ruby_subprocess(BUILD_IN_PROCESS, in_process)
    a = object_files(spawned)
    b = object_files(in_process)
    assert_equal 8, a.size
    assert_equal(a.map { |f| File.basename(f) }, b.map { |f| File.basename(f) })
    a.zip(b).each { |x, y| assert_equal File.binread(x), File.binread(y), File.basename(x) }
  end

  # libvips caches loads by file name. With `workers: 0` the cache is in
  # Jekyll's own process, which lives through every `jekyll serve` rebuild.
  def test_in_process_mode_reads_a_changed_file_again
    dir = fixture_copy("index.html" => "---\n---\n{% asset logo.png magick:format='webp' @path %}\n",
                       "resized.html" => nil)
    out = ruby_subprocess(<<~RUBY, dir, Base64.strict_encode64(png(12, 8, seed: 120)))
      require "base64"
      require "jekyll"
      require "jekyll-magik"
      site = Jekyll::Site.new(Jekyll.configuration("source" => ARGV[0], "destination" => File.join(ARGV[0], "_site"),
                                                   "quiet" => true, "magik" => { "workers" => 0 }))
      site.process
      first = File.read(File.join(ARGV[0], "_site/index.html")).strip
      File.binwrite(File.join(ARGV[0], "_assets/img/logo.png"), Base64.strict_decode64(ARGV[1]))
      site.process
      second = File.read(File.join(ARGV[0], "_site/index.html")).strip
      objects = [first, second].map do |url|
        dkey = url[/\\h{64}(?=\\.webp\\z)/]
        File.join(ARGV[0], ".jekyll-cache/magik/v1/objects", dkey[0, 2], "\#{dkey}.webp")
      end
      print objects.map { |path| Vips::Image.new_from_file(path).avg }.join(" ")
    RUBY
    first, second = out.split.map(&:to_f)
    refute_in_delta first, second, 1.0
  end

  ORIENTATION = File.expand_path("fixtures/orientation", __dir__)

  # The fixtures are 40x30, black on the left half, with EXIF orientation 6.
  # FastImage turns only JPEGs upright, so only JPEGs are rotated: a PNG or
  # WebP keeps its stored orientation instead of being rotated and then
  # squashed into the size predicted from the unrotated one.
  #
  # Whether to rotate follows FastImage, which reads the content: a JPEG
  # named .png is rotated too.
  def test_only_jpegs_are_turned_upright
    files = %w(png webp jpg).to_h { |ext| ["_assets/img/rotated.#{ext}", File.binread("#{ORIENTATION}/rotated.#{ext}")] }
    files["_assets/img/mislabeled.png"] = File.binread("#{ORIENTATION}/rotated.jpg")
    site = site_for(fixture_copy(files))
    site.reset
    object = lambda do |tag|
      dkey = render(tag, site: site)[/\h{64}(?=\.webp\z)/]
      File.join(site.magik.store.objects_dir, dkey[0, 2], "#{dkey}.webp")
    end
    %w(png webp).each do |ext|
      [%(magick:resize='20x'), %(magick:crop='40x30+0+0' magick:gravity='center' magick:resize='20x')].each do |args|
        image = pixels(object.call(%({% asset rotated.#{ext} #{args} magick:format='webp' @path %})), [[3, 7], [16, 7]])
        assert_equal [20, 15], image["size"], "#{ext} #{args}"
        assert_operator image["points"][0], :<, 60, "#{ext} #{args}: the left half isn't black"
        assert_operator image["points"][1], :>, 200, "#{ext} #{args}: the right half isn't white"
      end
    end
    # Rotated 90 degrees clockwise: the black half is on top. (Other widths,
    # or the two would share one object: they have the same bytes.)
    { "rotated.jpg" => 20, "mislabeled.png" => 22 }.each do |name, width|
      image = pixels(object.call(%({% asset #{name} magick:resize='#{width}x' magick:format='webp' @path %})),
                     [[10, 3], [10, 25]])
      assert_equal [width, (width * 4 / 3.0).round], image["size"], name
      assert_operator image["points"][0], :<, 60, name
      assert_operator image["points"][1], :>, 200, name
    end
  end

  def test_a_source_libvips_reads_at_another_size_fails_the_job
    src = File.join(ORIENTATION, "rotated.png")
    stat = File.stat(src)
    dir = Dir.mktmpdir
    (@tmpdirs ||= []) << dir
    processor = Jekyll::Magik::Processor.new
    reply = processor.run(
      "id" => "x", "source" => src, "source_size" => stat.size,
      "source_mtime_ns" => (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec,
      "source_width" => 30, "source_height" => 40, "autorotate" => false,
      "steps" => [["resize", 15, 20]], "format" => "png", "quality" => nil,
      "tmp" => File.join(dir, ".tmp-x"), "output" => File.join(dir, "x.png")
    )
    refute reply["ok"]
    assert_includes reply["error"], "libvips reads #{src} as 40x30, not 30x40"
    refute File.exist?(File.join(dir, "x.png"))
  ensure
    processor&.stop
  end

  # Killed just before a job, it fails that job's exchange: the job runs
  # again on a new worker.
  def test_a_worker_that_dies_just_before_a_job_is_replaced
    processor = Jekyll::Magik::Processor.new
    assert_equal false, processor.run("id" => "a", "source" => "/nope.png")["ok"]
    dead = processor.pid
    Process.kill(:KILL, dead)
    assert_equal false, processor.run("id" => "b", "source" => "/nope.png")["ok"]
    refute_equal dead, processor.pid
  ensure
    processor&.stop
  end

  # Dead well before the next job (here, even reaped by someone else), it's
  # found before the job is sent: the job goes to a new worker, once.
  def test_a_worker_that_died_while_idle_is_found_before_the_next_job
    processor = Jekyll::Magik::Processor.new
    processor.run("id" => "a", "source" => "/nope.png")
    dead = processor.pid
    Process.kill(:KILL, dead)
    Process.wait(dead)
    sent = 0
    exchange = processor.method(:exchange)
    processor.define_singleton_method(:exchange) do |job|
      sent += 1
      exchange.call(job)
    end
    assert_equal false, processor.run("id" => "b", "source" => "/nope.png")["ok"]
    assert_equal 1, sent
    refute_equal dead, processor.pid
  ensure
    processor&.stop
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
