# frozen_string_literal: true

require "liquid"

module Jekyll
  module Magik
    # A `{% asset %}` tag's arguments, parsed once when Liquid parses the tag.
    #
    # Values containing `{{` or `{%` are compiled to Liquid templates here and
    # rendered on each call; every other value is reused as it is.
    # (jekyll-assets parsed the tag on each render, and rendered every string
    # value through Liquid.)
    #
    # The structure (keys, flags, namespaces) can't depend on Liquid, so it's
    # checked here, against what jekyll-magik supports. The error is kept and
    # raised when the tag renders, where the page is known.
    #
    # `magick:` arguments become a Transform: here when they have no Liquid,
    # else on each render, memoized by their rendered values (a srcset's
    # `magick:resize='{{n}}x'` renders a few widths, many times).
    class Plan
      LIQUID = /\{\{|\{%/

      # Flags that pick an output mode.
      MODES = %i(path inline).freeze

      # Transforms kept per tag for rendered `magick:` values.
      MAX_TRANSFORMS = 256

      # Keys jekyll-assets gives a meaning beyond an HTML attribute.
      RESERVED = {
        vips: "`vips:` arguments aren't supported (jekyll-magik reads the `magick:` syntax)",
        optim: "`optim:` arguments aren't supported",
        data: "`@data` (data URIs) isn't supported",
        pic: "`@pic` isn't supported",
        external: "external assets aren't supported",
        responsive: "`responsive:` isn't supported",
        asset: "`asset:` arguments aren't supported",
        srcset: "`srcset:` isn't supported"
      }.freeze

      attr_reader :markup, :args, :mode, :error

      def initialize(markup)
        @markup = markup.strip
        @args = Args.parse(markup)
        @dynamic = compile(@args)
        @mode = MODES.find { |m| @args[m] == true } || :img
        @transforms = {}
        validate!
        @transform = Transform.parse(@args[:magick]) if magick? && !dynamic_value?(@args[:magick])
      rescue Error => e
        @error = e
      end

      # Whether the tag has `magick:` arguments.
      def magick?
        @args.key?(:magick)
      end

      # The tag's Transform, or nil without `magick:`. args: render_args'.
      def transform(args)
        return nil unless magick?
        return @transform if @transform

        magick = args[:magick]
        @transforms.clear if @transforms.size >= MAX_TRANSFORMS
        @transforms[magick] ||= Transform.parse(magick)
      end

      def dynamic?
        @dynamic
      end

      # The arguments with their Liquid rendered in the tag's context.
      def render_args(context)
        dynamic? ? render_values(@args, context) : @args
      end

      # The HTML attributes, [[name, value], ...] in tag order.
      def attributes(args)
        args.filter_map do |key, value|
          [key, value] unless key == :argv1 || key == :magick || MODES.include?(key)
        end
      end

      def tag
        "{% asset #{markup} %}"
      end

      private

      def compile(value)
        case value
        when Hash
          value.transform_values! { |v| compile_value(v) }
          value.values.any? { |v| dynamic_value?(v) }
        else
          false
        end
      end

      def compile_value(value)
        case value
        when String then value.match?(LIQUID) ? Liquid::Template.parse(value) : value.freeze
        when Hash then value.transform_values { |v| compile_value(v) }
        when Array then value.map { |v| compile_value(v) }
        else value
        end
      end

      def dynamic_value?(value)
        case value
        when Liquid::Template then true
        when Hash then value.values.any? { |v| dynamic_value?(v) }
        when Array then value.any? { |v| dynamic_value?(v) }
        else false
        end
      end

      def render_values(value, context)
        case value
        when Liquid::Template then value.render!(context)
        when Hash then value.transform_values { |v| render_values(v, context) }
        when Array then value.map { |v| render_values(v, context) }
        else value
        end
      end

      def validate!
        raise UnknownAsset, "Unknown asset ''" unless @args.key?(:argv1)
        unless @args[:argv1].is_a?(String) || @args[:argv1].is_a?(Liquid::Template)
          raise NotSupported, "the asset name #{@args[:argv1].inspect} isn't a file name"
        end
        if MODES.all? { |m| @args[m] == true }
          raise NotSupported, "`@path` and `@inline` can't be used together"
        end
        raise NotSupported, "`@inline` can't be used with `magick:`" if magick? && @mode == :inline

        @args.each { |key, value| validate_key!(key, value) unless key == :argv1 }
      end

      def validate_key!(key, value)
        return validate_magick!(value) if key == :magick
        raise NotSupported, RESERVED[key] if RESERVED.key?(key)

        case value
        when true
          return if MODES.include?(key)

          raise NotSupported, "`@#{key}` isn't supported"
        when false then raise NotSupported, "`!#{key}` isn't supported"
        when nil then raise NotSupported, "`#{key}` without a value isn't supported"
        when Array then raise NotSupported, "`#{key}` given more than once isn't supported"
        when Hash then raise NotSupported, "`#{key}:` arguments aren't supported"
        end
        raise NotSupported, "`#{key}=` with a value isn't supported" if MODES.include?(key)
        raise NotSupported, "`#{key}` isn't a valid HTML attribute name" unless Html.valid_name?(key)
      end

      def validate_magick!(value)
        unless value.is_a?(Hash)
          raise NotSupported, "`magick` arguments are namespaced: `magick:resize='600x'`, `@magick:strip`"
        end

        Transform.check!(value)
      end
    end
  end
end
