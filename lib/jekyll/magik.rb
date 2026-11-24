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

    # An incremental build doesn't render the pages it skips, so their tags
    # never mark their assets used, and Jekyll's cleaner would delete them
    # while the pages that refer to them stay. Api#after_render uses them
    # again from the page map; where it can't, this keeps jekyll-magik's
    # files, as jekyll-assets kept every file in its manifest.
    module CleanerMethods
      private

      def obsolete_files
        files = super
        return files unless site.incremental? && site.respond_to?(:magik)

        files.reject { |path| site.magik.keep_on_incremental?(path) }
      end
    end

    # Only jekyll-assets itself, not any code that opens the namespace
    # (beekeeper-studio/web's _plugins/stable_proxy_keys.rb does).
    def self.check_conflict!
      raise Conflict, CONFLICT if defined?(Jekyll::Assets::Env) || defined?(Jekyll::Assets::Tag)

      tag = Liquid::Template.tags["asset"]
      return if tag.nil? || tag == Jekyll::Magik::Tag

      raise Conflict, "jekyll-magik's {% asset %} tag was replaced by #{tag}. #{CONFLICT}"
    end
  end
end

Jekyll::Magik.check_conflict!
Jekyll::Site.include(Jekyll::Magik::SiteMethods)
Jekyll::Cleaner.prepend(Jekyll::Magik::CleanerMethods)
Liquid::Template.register_tag("asset", Jekyll::Magik::Tag)
Liquid::Template.register_filter(Jekyll::Magik::Filters)

# jekyll-assets may be required after jekyll-magik, so check again once every
# plugin is loaded. Creating the API here also reads and checks the config,
# and loads the cache, once per process.
Jekyll::Hooks.register :site, :after_init do |site|
  Jekyll::Magik.check_conflict!
  site.magik.store
end

Jekyll::Hooks.register :site, :after_reset do |site|
  site.magik.reset!
end

Jekyll::Hooks.register :site, :pre_render do |_site, payload|
  payload["assets"] ||= Jekyll::Magik::AssetsDrop.new
end

Jekyll::Hooks.register :site, :post_render do |site|
  site.magik.after_render
end

Jekyll::Hooks.register :site, :post_write do |site|
  site.magik.after_write
end
