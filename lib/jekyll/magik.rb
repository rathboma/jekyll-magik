# frozen_string_literal: true

require_relative "magik/core"

module Jekyll
  module Magik
    CONFLICT = "jekyll-magik can't be used with jekyll-assets: both define the {% asset %} tag. " \
               "Remove jekyll-assets from your Gemfile and from `plugins:` in _config.yml"

    # `site.magik`, created on first use.
    module SiteMethods
      def magik
        @magik ||= Jekyll::Magik::Api.new(self)
      end
    end

    def self.check_conflict!
      raise Conflict, CONFLICT if defined?(Jekyll::Assets)

      tag = Liquid::Template.tags["asset"]
      return if tag.nil? || tag == Jekyll::Magik::Tag

      raise Conflict, "jekyll-magik's {% asset %} tag was replaced by #{tag}. #{CONFLICT}"
    end
  end
end

Jekyll::Magik.check_conflict!
Jekyll::Site.include(Jekyll::Magik::SiteMethods)
Liquid::Template.register_tag("asset", Jekyll::Magik::Tag)
Liquid::Template.register_filter(Jekyll::Magik::Filters)

# jekyll-assets may be required after jekyll-magik, so check again once every
# plugin is loaded. Creating the API here also reads and checks the config.
Jekyll::Hooks.register :site, :after_init do |site|
  Jekyll::Magik.check_conflict!
  site.magik
end

Jekyll::Hooks.register :site, :after_reset do |site|
  site.magik.reset!
end
