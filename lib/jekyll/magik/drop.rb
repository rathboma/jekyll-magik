# frozen_string_literal: true

require "liquid"

module Jekyll
  module Magik
    # Stands in for jekyll-assets' `assets` drop (`{{ assets["logo.png"].width }}`),
    # which jekyll-magik doesn't have, so that a template using it fails the
    # build instead of quietly getting nothing.
    class AssetsDrop < Liquid::Drop
      def liquid_method_missing(name)
        raise NotSupported, "the `assets` drop (`{{ assets[\"#{name}\"] }}`) isn't supported by " \
                            "jekyll-magik; use the asset_url and asset_size filters"
      end
    end
  end
end
