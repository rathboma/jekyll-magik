# frozen_string_literal: true

require_relative "test_helper"

class TransformTest < Minitest::Test
  T = Jekyll::Magik::Transform

  def parse(hash)
    T.parse(hash)
  end

  def test_canonical_form
    t = parse(resize: "600x", crop: "600x300+0+0", gravity: "center", strip: true)
    assert_equal '{"gravity":"center","ops":[["resize","600x"],["crop","600x300+0+0"]]}', t.canonical
    t = parse(resize: "750x", format: "webp", quality: 80, strip: true)
    assert_equal '{"format":"webp","ops":[["resize","750x"]],"quality":80}', t.canonical
    assert_equal({ "ops" => [] }, parse(strip: true).to_h)
  end

  # The identity is the arguments normalized: quoting, number formats,
  # case, the order of settings and `strip` don't change it.
  def test_equivalent_arguments_are_the_same_transform
    a = parse(resize: "600x", format: "webp", quality: 80, strip: true)
    [
      { quality: "80", strip: true, format: "WEBP", resize: "0600x" },
      { format: "webp", resize: "600x", quality: "080" },
      { strip: true, resize: "600x", quality: 80, format: "webp" }
    ].each do |args|
      b = parse(args)
      assert_equal a, b, args.inspect
      assert_equal a.hash, b.hash
      assert a.eql?(b)
    end
    assert_equal parse(format: "jpg"), parse(format: "jpeg")
    assert_equal parse(crop: "10x10+0+0", gravity: "Center"), parse(gravity: "center", crop: "10x10+00+0")
  end

  def test_geometry_order_is_part_of_the_identity
    a = parse(resize: "300x", crop: "600x300+0+0", gravity: "center")
    b = parse(crop: "600x300+0+0", resize: "300x", gravity: "center")
    refute_equal a, b
    assert_equal [300, 300], a.output_size(1000, 1000)
    assert_equal [300, 150], b.output_size(1000, 1000)
  end

  # Measured with `mogrify -resize 600x -crop 600x300+0+0 -gravity center`
  # (and the other two) on ImageMagick 6.9.12.
  IMAGEMAGICK = {
    [1000, 667] => [[600, 300], [640, 427], [590, 300]],
    [1001, 333] => [[600, 200], [640, 213], [590, 200]],
    [333, 1001] => [[600, 300], [640, 1924], [590, 300]],
    [599, 401] => [[600, 300], [640, 428], [590, 300]],
    [1280, 720] => [[600, 300], [640, 360], [590, 299]],
    [7, 5] => [[600, 300], [640, 457], [590, 300]],
    [3000, 7] => [[600, 1], [640, 1], [590, 1]],
    [640, 1] => [[600, 1], [640, 1], [590, 1]],
    [2, 3] => [[600, 300], [640, 960], [590, 300]]
  }.freeze

  def test_output_size_matches_imagemagick
    thumb = parse(resize: "600x", crop: "600x300+0+0", gravity: "center")
    resize = parse(resize: "640x")
    offset = parse(resize: "600x", crop: "600x300+10-20", gravity: "center")
    IMAGEMAGICK.each do |(w, h), expected|
      assert_equal expected, [thumb, resize, offset].map { |t| t.output_size(w, h) }, "#{w}x#{h}"
    end
  end

  def test_steps
    t = parse(resize: "600x", crop: "600x300+0+0", gravity: "center")
    assert_equal [["resize", 600, 400], ["crop", 0, 50, 600, 300]], t.steps(1000, 667)
    assert_equal [], parse(format: "webp").steps(10, 10)
    assert_equal [10, 10], parse(format: "webp").output_size(10, 10)
  end

  def test_a_crop_outside_the_image_raises
    error = assert_raises(Jekyll::Magik::Error) do
      parse(crop: "10x10+500+0", gravity: "center").output_size(100, 100)
    end
    assert_equal "`magick:crop='10x10+500+0'` is outside the 100x100 image", error.message
  end

  def test_output_format
    source = ->(type) { Struct.new(:content_type).new(type) }
    assert_equal "png", parse(resize: "1x").output_format(source.call("image/png"))
    assert_equal "jpg", parse(resize: "1x").output_format(source.call("image/jpeg"))
    assert_equal "webp", parse(format: "webp").output_format(source.call("image/jpeg"))
    %w(image/gif image/svg+xml video/mp4).each do |type|
      error = assert_raises(Jekyll::Magik::NotSupported) { parse(resize: "1x").output_format(source.call(type)) }
      assert_equal "resizing #{type} files isn't supported (only PNG, JPEG and WebP)", error.message
    end
  end

  def test_out_of_scope_arguments_raise
    {
      { extent: "10x10" } => "`magick:extent` isn't supported",
      { rotate: 90 } => "`magick:rotate` isn't supported",
      { resize: %w(1x 2x) } => "`magick:resize` given more than once isn't supported",
      { resize: { x: 1 } } => "`magick:resize:` arguments aren't supported",
      { strip: false } => "`!magick:strip` isn't supported: output is always stripped",
      { strip: "yes" } => "`magick:strip` takes no value: use `@magick:strip`",
      { resize: true } => "`@magick:resize` needs a value",
      { quality: false } => "`!magick:quality` isn't supported",
      { resize: "x600" } => "`magick:resize='x600'` isn't supported: give a width, like '600x'",
      { resize: "600x400" } => "`magick:resize='600x400'` isn't supported",
      { resize: "600x!" } => "`magick:resize='600x!'` isn't supported",
      { resize: "50%" } => "`magick:resize='50%'` isn't supported",
      { resize: 600 } => "`magick:resize='600'` isn't supported",
      { resize: "0x" } => "`magick:resize='0x'` isn't supported",
      { crop: "600x300", gravity: "center" } => "`magick:crop='600x300'` isn't supported",
      { crop: "1x1+0+0" } => "`magick:crop` without `magick:gravity='center'` isn't supported",
      { crop: "1x1+0+0", gravity: "north" } => "`magick:gravity='north'` isn't supported: only 'center' is",
      { gravity: "center" } => "`magick:gravity` without `magick:crop` isn't supported",
      { quality: 0 } => "`magick:quality='0'` isn't supported: give a whole number from 1 to 100",
      { quality: 101 } => "`magick:quality='101'` isn't supported",
      { quality: 80.5 } => "`magick:quality='80.5'` isn't supported",
      { format: "png" } => "`magick:format='png'` isn't supported: only 'jpg' and 'webp' are",
      { format: "avif" } => "`magick:format='avif'` isn't supported"
    }.each do |args, message|
      error = assert_raises(Jekyll::Magik::NotSupported, args.inspect) { parse(args) }
      assert error.message.start_with?(message), "#{args.inspect}: #{error.message}"
    end
  end
end
