# frozen_string_literal: true

module Jekyll
  module Magik
    # Every error jekyll-magik raises. They aren't Liquid::Error subclasses on
    # purpose: Liquid renders those inline instead of failing the build.
    class Error < StandardError; end

    # Something jekyll-assets can do that jekyll-magik doesn't (yet). Raised
    # rather than emitting something different from jekyll-assets.
    class NotSupported < Error; end

    # No file in the asset load paths matches the name.
    class UnknownAsset < Error; end

    # A bad value in _config.yml.
    class ConfigError < Error; end

    # jekyll-assets is loaded too. Both define {% asset %}.
    class Conflict < Error; end
  end
end
