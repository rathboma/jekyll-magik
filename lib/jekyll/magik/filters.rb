# frozen_string_literal: true

module Jekyll
  module Magik
    # Liquid filters for an asset's URL and size, for templates that build
    # their own markup (meta tags, JSON-LD, srcsets).
    #
    #   {{ "blog/default.jpg" | asset_url }}
    #   {% assign size = "screenshots/main-dark.png" | asset_size %}
    module Filters
      # The asset's digested URL. Marks it used, so it's written to _site.
      # Raises for a missing asset, so a renamed file fails the build instead
      # of leaving a broken URL. Empty for an empty name.
      def asset_url(name)
        return nil if name.nil? || name.to_s.empty?

        magik_api.find!(name.to_s, page: @context.registers[:page]).url
      end

      # [width, height] in pixels. Doesn't mark the asset used.
      def asset_size(name)
        source = magik_api.lookup(name.to_s)
        raise UnknownAsset, "Unknown asset '#{name}' (asset_size)#{magik_in_page}" unless source
        raise NotSupported, "asset_size: #{source.logical_path} isn't an image" unless source.image?

        source.dimensions
      end

      # jekyll-assets' `asset` filter, which jekyll-magik doesn't have.
      def asset(name, *)
        raise NotSupported, "the `asset` filter isn't supported by jekyll-magik; " \
                            "use the {% asset #{name} %} tag#{magik_in_page}"
      end

      private

      def magik_api
        site = @context.registers[:site]
        raise Error, "jekyll-magik's filters need a Jekyll site" unless site

        @context.registers[:magik] || site.magik
      end

      def magik_in_page
        page = @context.registers[:page]
        path = page && (page["relative_path"] || page["path"])
        path ? " in #{path}" : ""
      end
    end
  end
end
