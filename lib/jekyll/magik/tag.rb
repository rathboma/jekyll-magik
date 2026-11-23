# frozen_string_literal: true

require "liquid"

module Jekyll
  module Magik
    # {% asset name [attributes] [@path | @inline] %}
    #
    # - default: an <img> with the tag's attributes in order, then `src`, and
    #   `integrity` and `crossorigin="anonymous"` when
    #   `assets: defaults: img: integrity` is on, as jekyll-assets wrote it
    # - `@path`: the asset's URL only
    # - `@inline`: an SVG's markup, with the attributes on its root element
    class Tag < Liquid::Tag
      def initialize(tag_name, markup, parse_context)
        super
        @plan = Plan.new(markup)
      end

      def render(context)
        site = context.registers[:site]
        raise Error, "{% asset %} needs a Jekyll site to render" unless site

        api = context.registers[:magik] || site.magik
        Renderer.new(api).render(@plan, context)
      end
    end

    # Turns a tag's Plan into markup. Separate from the Liquid tag so the
    # parity scripts can run it next to jekyll-assets.
    class Renderer
      def initialize(api)
        @api = api
      end

      def render(plan, context)
        page = context.registers[:page]
        raise annotate(plan.error, plan, page) if plan.error

        args = plan.render_args(context)
        source = find(args[:argv1], plan, page)
        check_mode!(plan.mode, source)
        @api.use(source, page: page)
        case plan.mode
        when :path then source.url
        when :inline then inline(source, plan, args)
        else img(source, plan, args)
        end
      rescue Error => e
        raise e if e.message.include?(plan.tag)

        raise annotate(e, plan, page, source)
      end

      private

      def find(name, plan, page)
        name = name.to_s
        @api.lookup(name) || raise(UnknownAsset, "Unknown asset '#{name}'#{in_page(page)} (#{plan.tag})")
      end

      # Before the asset is used: a tag that raises mustn't write a file (or,
      # later, start resizing one).
      def check_mode!(mode, source)
        case mode
        when :inline
          raise NotSupported, "`@inline` only supports SVG files" unless source.svg?
        when :img
          unless Mime::IMG_TYPES.include?(source.content_type)
            raise NotSupported, "#{source.content_type} assets can only be used with `@path`"
          end
        end
      end

      def img(source, plan, args)
        attributes = plan.attributes(args)
        set(attributes, :src, source.url)
        if @api.config.img_integrity && !args.key?(:integrity)
          set(attributes, :integrity, source.integrity)
          attributes << [:crossorigin, "anonymous"] unless args.key?(:crossorigin)
        end
        Html.img(attributes)
      end

      def inline(source, plan, args)
        Svg.inline(File.binread(source.filename), plan.attributes(args), filename: source.filename)
      end

      # Like jekyll-assets' `args[key] = value`: a key the tag already has
      # keeps its place.
      def set(attributes, key, value)
        existing = attributes.find { |name, _| name == key }
        existing ? existing[1] = value : attributes << [key, value]
      end

      def annotate(error, plan, page, source = nil)
        message = error.message
        message += " (#{source.filename})" if source && !message.include?(source.filename)
        error.class.new("#{message}#{in_page(page)} (#{plan.tag})")
      end

      def in_page(page)
        path = page && (page["relative_path"] || page["path"])
        path ? " in #{path}" : ""
      end
    end
  end
end
