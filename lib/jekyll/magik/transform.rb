# frozen_string_literal: true

require "json"

module Jekyll
  module Magik
    # A tag's `magick:` arguments, parsed: geometry operations (`resize`,
    # `crop`) in the order given, and settings for the whole transform
    # (`gravity`, `quality`, `format`).
    #
    #   t = Transform.parse(resize: "600x", crop: "600x300+0+0", gravity: "center", strip: true)
    #   t.canonical             # => '{"gravity":"center","ops":[["resize","600x"],["crop","600x300+0+0"]]}'
    #   t.output_size(1000, 667) # => [600, 300]
    #
    # Its identity, `canonical`, is the arguments normalized: numbers written
    # one way, settings in name order, geometry in the order given (that
    # changes the result), and `strip` left out, since output is always
    # stripped. HTML attributes and built-in defaults are never part of it.
    #
    # Only what beekeeper-studio/web uses is supported (the table in #3).
    # Anything else raises NotSupported rather than doing something other
    # than ImageMagick would.
    class Transform
      KEYS = %i(resize crop gravity quality format strip).freeze
      RESIZE = /\A0*([1-9]\d*)x\z/
      CROP = /\A0*([1-9]\d*)x0*([1-9]\d*)([+-]\d+)([+-]\d+)\z/
      FORMATS = { "jpg" => "jpg", "jpeg" => "jpg", "webp" => "webp" }.freeze
      # The types a transform reads, and the format each is written in unless
      # `format` converts it.
      SOURCE_FORMATS = { "image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp" }.freeze

      # `resize='Wx'`: W wide, keeping the aspect ratio.
      Resize = Struct.new(:width) do
        def name = "resize"
        def to_s = "#{width}x"
      end

      # `crop='WxH+X+Y'`, with `gravity='center'`.
      Crop = Struct.new(:width, :height, :x, :y) do
        def name = "crop"
        def to_s = Kernel.format("%<w>dx%<h>d%<x>+d%<y>+d", w: width, h: height, x: x, y: y)
      end

      attr_reader :ops, :gravity, :quality, :format, :canonical

      class << self
        # Checks the arguments' keys and the kinds of their values. Values
        # may still be Liquid templates here (Plan calls it at parse time).
        def check!(magick)
          magick.each { |key, value| check_key!(key, value) }
          if magick.key?(:crop) && !magick.key?(:gravity)
            raise NotSupported, "`magick:crop` without `magick:gravity='center'` isn't supported"
          end
          return unless magick.key?(:gravity) && !magick.key?(:crop)

          raise NotSupported, "`magick:gravity` without `magick:crop` isn't supported"
        end

        # A Transform from rendered arguments: { resize: "600x", strip: true }.
        def parse(magick)
          check!(magick)
          ops = []
          settings = {}
          magick.each do |key, value|
            case key
            when :resize then ops << parse_resize(value)
            when :crop then ops << parse_crop(value)
            when :gravity then settings[:gravity] = parse_gravity(value)
            when :quality then settings[:quality] = parse_quality(value)
            when :format then settings[:format] = parse_format(value)
            end
          end
          new(ops: ops, **settings)
        end

        # The Transform whose `to_h` this is (from the page map), or nil if
        # it isn't one.
        def from_h(hash)
          magick = hash.fetch("ops").to_h { |name, value| [name.to_sym, value] }
          magick.merge!(hash.slice("gravity", "quality", "format").transform_keys(&:to_sym))
          transform = parse(magick)
          transform if transform.to_h == hash
        rescue Error, KeyError, TypeError, ArgumentError, NoMethodError
          nil
        end

        private

        def check_key!(key, value)
          raise NotSupported, "`magick:#{key}` isn't supported" unless KEYS.include?(key)

          case value
          when Array then raise NotSupported, "`magick:#{key}` given more than once isn't supported"
          when Hash then raise NotSupported, "`magick:#{key}:` arguments aren't supported"
          end
          return check_strip!(value) if key == :strip

          raise NotSupported, "`@magick:#{key}` needs a value" if value == true
          raise NotSupported, "`!magick:#{key}` isn't supported" if value == false
          raise NotSupported, "`magick:#{key}` needs a value" if value.nil?
        end

        def check_strip!(value)
          return if value == true
          raise NotSupported, "`!magick:strip` isn't supported: output is always stripped" if value == false

          raise NotSupported, "`magick:strip` takes no value: use `@magick:strip`"
        end

        def parse_resize(value)
          m = value.is_a?(String) && RESIZE.match(value)
          return Resize.new(m[1].to_i) if m

          raise NotSupported, "`magick:resize='#{value}'` isn't supported: give a width, like '600x'"
        end

        def parse_crop(value)
          m = value.is_a?(String) && CROP.match(value)
          return Crop.new(m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i) if m

          raise NotSupported,
                "`magick:crop='#{value}'` isn't supported: give a size and offsets, like '600x300+0+0'"
        end

        def parse_gravity(value)
          return "center" if value.is_a?(String) && value.casecmp?("center")

          raise NotSupported, "`magick:gravity='#{value}'` isn't supported: only 'center' is"
        end

        def parse_quality(value)
          q = case value
              when Integer then value
              when /\A\d+\z/ then value.to_i
              end
          return q if q && (1..100).cover?(q)

          raise NotSupported, "`magick:quality='#{value}'` isn't supported: give a whole number from 1 to 100"
        end

        def parse_format(value)
          format = value.is_a?(String) && FORMATS[value.downcase]
          return format if format

          raise NotSupported, "`magick:format='#{value}'` isn't supported: only 'jpg' and 'webp' are"
        end
      end

      def initialize(ops:, gravity: nil, quality: nil, format: nil)
        @ops = ops.map(&:freeze).freeze
        @gravity = gravity
        @quality = quality
        @format = format
        @canonical = JSON.generate(to_h).freeze
        freeze
      end

      # The identity as a hash, in key order: what `canonical` serializes,
      # what the worker gets and what magik-manifest.json lists.
      def to_h
        h = {}
        h["format"] = format if format
        h["gravity"] = gravity if gravity
        h["ops"] = ops.map { |op| [op.name, op.to_s] }
        h["quality"] = quality if quality
        h
      end

      # The format the output is written in: `format`, else the source's.
      # Raises for sources a transform can't read.
      def output_format(source)
        from = SOURCE_FORMATS[source.content_type]
        unless from
          raise NotSupported,
                "resizing #{source.content_type} files isn't supported (only PNG, JPEG and WebP)"
        end

        format || from
      end

      # The operations in pixels for a source of that size (after EXIF
      # rotation), each with the size it leaves: [["resize", w, h],
      # ["crop", x, y, w, h], ...]. ImageMagick's arithmetic, so the output
      # is the size ImageMagick's would be.
      def steps(width, height)
        ops.map do |op|
          case op
          when Resize
            # ParseMetaGeometry: one scale factor, each side rounded.
            scale = op.width.to_f / width
            width = [((scale * width) + 0.5).floor, 1].max
            height = [((scale * height) + 0.5).floor, 1].max
            ["resize", width, height]
          when Crop
            x, y, width, height = crop_box(op, width, height)
            ["crop", x, y, width, height]
          end
        end
      end

      # [width, height] of the output for a source of that size.
      def output_size(width, height)
        last = steps(width, height).last
        last ? last.last(2) : [width, height]
      end

      def ==(other)
        other.is_a?(Transform) && canonical == other.canonical
      end
      alias eql? ==

      def hash
        canonical.hash
      end

      def to_s
        canonical
      end

      def inspect
        "#<#{self.class.name} #{canonical}>"
      end

      private

      # GravityAdjustGeometry for center gravity (integer halves), then
      # CropImage's clamp to the image: a box running off an edge gives a
      # smaller image, never padding. ImageMagick makes a 1x1 image of a box
      # entirely outside; that raises here.
      def crop_box(crop, width, height)
        x = crop.x + (width / 2) - (crop.width / 2)
        y = crop.y + (height / 2) - (crop.height / 2)
        w = x + crop.width > width ? width - x : crop.width
        h = y + crop.height > height ? height - y : crop.height
        if x.negative?
          w += x
          x = 0
        end
        if y.negative?
          h += y
          y = 0
        end
        return [x, y, w, h] if w.positive? && h.positive?

        raise Error, "`magick:crop='#{crop}'` is outside the #{width}x#{height} image"
      end
    end
  end
end
