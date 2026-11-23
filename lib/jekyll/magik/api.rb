# frozen_string_literal: true

module Jekyll
  module Magik
    # `site.magik`: jekyll-magik's state for a site, and the Ruby API for
    # plugins (in place of `site.sprockets`).
    #
    #   asset = site.magik.find!("blog/default.jpg")
    #   asset.url     # => "/assets/img/blog/default-<sha512>.jpg"
    #   asset.width   # => 1200
    #
    # `find`, `find!` and `url` mark the asset used, so it's written to _site
    # even when no tag refers to it (social images in meta tags, JSON-LD).
    class Api
      attr_reader :site, :config

      # write_files: false keeps used assets out of site.static_files (the
      # parity scripts run next to jekyll-assets, which writes them).
      def initialize(site, write_files: true)
        @site = site
        @config = Config.new(site.config)
        @write_files = write_files
        @config.warnings.each { |w| Jekyll.logger.warn("jekyll-magik:", w) }
        exclude_cache_dir
        reset!
      end

      # A new build: files may have changed, and Jekyll has emptied
      # site.static_files.
      def reset!
        @resolver = nil
        @used = {}
      end

      def resolver
        @resolver ||= Resolver.new(config)
      end

      # The Source for a name, without marking it used. nil if there's none.
      def lookup(name)
        resolver.find(name)
      end

      # The Source for a name, marked used. nil if there's none.
      def find(name, page: nil)
        source = lookup(name)
        use(source, page: page) if source
        source
      end

      def find!(name, page: nil)
        find(name, page: page) || raise(UnknownAsset, "Unknown asset '#{name}'#{in_page(page)}")
      end

      def url(name, page: nil)
        find!(name, page: page).url
      end

      # Marks a source used in this build: Jekyll writes it to _site with the
      # site's other static files, and regenerates the page when it changes.
      def use(source, page: nil)
        add_dependency(page, source)
        return if @used.key?(source.dest_path)

        @used[source.dest_path] = source
        site.static_files << AssetFile.new(site, source) if @write_files
      end

      # The sources used so far in this build.
      def used
        @used.values
      end

      private

      def add_dependency(page, source)
        path = page && page["path"]
        return unless path && site.regenerator

        site.regenerator.add_dependency(site.in_source_dir(path), source.filename)
      end

      def in_page(page)
        path = page && (page["relative_path"] || page["path"])
        path ? " in #{path}" : ""
      end

      # .jekyll-cache is excluded by Jekyll already; a cache_dir elsewhere in
      # the source must be excluded too.
      def exclude_cache_dir
        relative = config.relative_cache_dir
        return if relative.nil? || relative.start_with?(".jekyll-cache/")

        site.exclude << relative unless site.exclude.include?(relative)
      end
    end
  end
end
