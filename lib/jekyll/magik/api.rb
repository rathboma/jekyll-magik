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
      # The shape of a digested asset path that beekeeper-studio/web's
      # translation Worker and IndexNow recognise (DIGESTED in
      # workers/translate/src/assets.ts): ASCII word characters, `.`, `/` and
      # `-`, the digest in lowercase hex, and a lowercase extension.
      DIGESTED_PATH = %r{\A[\w./-]+?-[0-9a-f]{64,128}\.[a-z0-9]+\z}
      # The names jekyll-magik writes: digested originals, and names
      # sprockets considers digested already.
      OUTPUT_NAME = /-(?:\h{128}\.[^.\/]+|[0-9a-zA-Z]{7,128}\.digested)/

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
        depend(page, source)
        return if @used.key?(source.dest_path)

        @used[source.dest_path] = source
        warn_outside_grammar(source)
        site.static_files << AssetFile.new(site, source) if @write_files
      end

      # Regenerates the page when the source changes (incremental builds and
      # `jekyll serve`), keyed the way Jekyll's include tag keys pages.
      def depend(page, source)
        path = page && page["path"]
        return unless path && site.regenerator

        page_path = if page["collection"]
                      site.in_source_dir(site.config["collections_dir"], path)
                    else
                      site.in_source_dir(path)
                    end
        site.regenerator.add_dependency(page_path, source.filename)
      end

      # Whether an incremental build should leave a file in _site that no
      # rendered page used this time: one of jekyll-magik's, in the asset
      # destination. See CleanerMethods.
      # Directories go too: the cleaner deletes a directory with everything
      # in it, so the destination, the directories above it and the ones in it
      # are kept (their other obsolete files are listed, and deleted, one by
      # one).
      def keep_on_incremental?(path)
        root = site.in_dest_dir(config.destination.to_s)
        inside = path.start_with?(File.join(root, ""))
        if File.directory?(path)
          inside || path == root || root.start_with?(File.join(path, ""))
        else
          inside && File.basename(path).match?(OUTPUT_NAME)
        end
      end

      # The sources used so far in this build.
      def used
        @used.values
      end

      private

      # Translated pages and IndexNow key text by asset URLs with their
      # digest taken out; a URL they can't parse makes them see new text.
      # jekyll-assets served such names, so this only warns.
      def warn_outside_grammar(source)
        return if DIGESTED_PATH.match?(source.digest_path)

        Jekyll.logger.warn("jekyll-magik:", "#{source.url} (#{source.filename}) isn't of the form " \
                                            "<name>-<digest>.<ext> with only letters, digits, _ . / - " \
                                            "and a lowercase extension")
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
