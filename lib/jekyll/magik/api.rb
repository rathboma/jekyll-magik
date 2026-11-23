# frozen_string_literal: true

require "json"
require "set"

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
    #
    # It holds the Store, loaded once per process, and per build: the
    # Resolver, the Registry of derivatives, the files to write and which
    # page used which asset (persisted, so that an incremental build keeps
    # the assets of the pages it skips).
    class Api
      # The shape of a digested asset path that beekeeper-studio/web's
      # translation Worker and IndexNow recognise (DIGESTED in
      # workers/translate/src/assets.ts): ASCII word characters, `.`, `/` and
      # `-`, the digest in lowercase hex, and a lowercase extension.
      DIGESTED_PATH = %r{\A[\w./-]+?-[0-9a-f]{64,128}\.[a-z0-9]+\z}
      # The names jekyll-magik writes: digested originals, derivatives, and
      # names sprockets considers digested already.
      OUTPUT_NAME = /-(?:\h{128}\.[^.\/]+|\h{#{Registry::TKEY_LENGTH}}-\h{64}\.[^.\/]+|[0-9a-zA-Z]{7,128}\.digested)/
      DERIVATIVE_PATH = /-(\h{64})\.([a-z0-9]+)\z/

      # A derivative an incremental build kept for a page it didn't render.
      Restored = Struct.new(:path, :url, :logical_path, :canonical, :dkey, :ext, keyword_init: true)

      attr_reader :site, :config
      attr_writer :processor

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
        @registry = nil
        @used = {}
        @page_assets = {}
        @page_keys = {}.compare_by_identity
        @live_pages = nil
        @page_map_incomplete = false
        @store&.reset!
      end

      # The cache, loaded on first use and kept for the life of the process.
      def store
        @store ||= Store.new(config.cache_dir)
      end

      def processor
        @processor ||= Processor.for(config)
      end

      def resolver
        @resolver ||= Resolver.new(config, memo: store)
      end

      def registry
        @registry ||= Registry.new(config: config, store: store, processor: processor)
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
        record(page, source)
        return if @used.key?(source.dest_path)

        @used[source.dest_path] = source
        warn_outside_grammar(source.digest_path, source.url, source.filename)
        site.static_files << AssetFile.new(site, source) if @write_files
      end

      # The derivative of a source made by a transform, marked used:
      # processed now unless the cache has it. Returns a Registry::Reference
      # (url, width, height, ...).
      def derive(source, transform, page: nil)
        ref = registry.reference(source, transform)
        depend(page, source)
        key = record(page, ref)
        ref.derivative.pages << key if key
        return ref if @used.key?(ref.dest_path)

        @used[ref.dest_path] = ref
        warn_outside_grammar(ref.path, ref.url, source.filename)
        if @write_files
          site.static_files << DerivativeFile.new(site, ref.dest_path, store.object_path(ref.dkey, ref.ext))
        end
        ref
      end

      # Subresource integrity of a derivative (`magik.derivative_integrity`).
      def integrity(ref)
        registry.integrity(ref.derivative)
      end

      # Regenerates the page when the source changes (incremental builds and
      # `jekyll serve`), keyed the way Jekyll's include tag keys pages.
      def depend(page, source)
        key = page_key(page)
        site.regenerator.add_dependency(key, source.filename) if key && site.regenerator
      end

      # The originals used so far in this build.
      def used
        @used.values.grep(Source)
      end

      # The derivatives used so far in this build (Registry::References).
      def derivatives
        @used.values.grep(Registry::Reference)
      end

      # This build's numbers, for the summary and tests.
      def stats
        s = registry.stats
        { references: s.references, derivatives: registry.derivatives.size, cached: s.cached,
          processed: s.processed, seconds: s.seconds, originals: used.size }
      end

      # After rendering (the :site, :post_render hook): records the assets of
      # every page this build rendered, and, in an incremental build, uses
      # the assets of the pages it skipped again, so they stay in _site.
      def after_render
        @live_pages = Set.new
        each_page do |page, key|
          @live_pages << key
          if !site.incremental? || site.regenerator.regenerate?(page)
            store.update_page(key, page_entries(@page_assets[key]))
          else
            restore(key)
          end
        end
        site.static_files << ManifestFile.new(site, self) if config.manifest && @write_files
      end

      # After writing (the :site, :post_write hook): saves the cache, runs GC
      # after a full build, and logs the summary.
      def after_write
        gc = store.save(full_build: full_build?, site_source: site.source, live_pages: @live_pages,
                        gc_max_age_days: config.gc_max_age_days)
        Jekyll.logger.info("jekyll-magik:", summary(gc))
      end

      # A build that renders every page: not `jekyll serve` or `--watch`
      # regenerations, `--incremental` or `--limit-posts`. Only these prune
      # the cache, since only they use every asset the site has.
      def full_build?
        !site.incremental? && !site.config["serving"] && !site.config["watch"] &&
          site.config["limit_posts"].to_i.zero?
      end

      # Whether an incremental build should leave a file in _site that no
      # page used this time. Normally not: the page map put back every asset
      # of every page the build skipped. When it couldn't (the cache was
      # deleted, or a skipped page was never recorded), every file of
      # jekyll-magik's in the asset destination is kept. See CleanerMethods.
      # Directories go too: the cleaner deletes a directory with everything
      # in it, so the destination, the directories above it and the ones in it
      # are kept (their other obsolete files are listed, and deleted, one by
      # one).
      def keep_on_incremental?(path)
        return false unless @page_map_incomplete

        root = site.in_dest_dir(config.destination.to_s)
        inside = path.start_with?(File.join(root, ""))
        if File.directory?(path)
          inside || path == root || root.start_with?(File.join(path, ""))
        else
          inside && File.basename(path).match?(OUTPUT_NAME)
        end
      end

      # Everything this build wrote, for magik-manifest.json.
      def manifest
        originals = {}
        derivatives = {}
        @used.each_value do |item|
          case item
          when Source
            originals[item.url] = { "logical_path" => item.logical_path }
          when Registry::Reference
            derivatives[item.url] = { "logical_path" => item.logical_path, "transform" => item.transform.to_h,
                                      "width" => item.width, "height" => item.height }
          when Restored
            entry = store.entry(item.dkey) || {}
            derivatives[item.url] = { "logical_path" => item.logical_path,
                                      "transform" => JSON.parse(item.canonical),
                                      "width" => entry["width"], "height" => entry["height"] }
          end
        end
        { "derivatives" => derivatives.sort.to_h, "originals" => originals.sort.to_h }
      end

      private

      # The page's key: its source file's absolute path, as Jekyll's
      # regenerator keys it. `page` is what tags see as registers[:page].
      def page_key(page)
        return nil unless page

        @page_keys.fetch(page) do
          path = page["path"]
          @page_keys[page] = if path.nil?
                               nil
                             elsif page["collection"]
                               site.in_source_dir(site.config["collections_dir"], path)
                             else
                               site.in_source_dir(path)
                             end
        end
      end

      # Every page and document of the site, with its key.
      def each_page
        site.pages.each { |page| yield page, site.in_source_dir(page.path) }
        site.collections.each_value do |collection|
          collection.docs.each do |doc|
            yield doc, site.in_source_dir(site.config["collections_dir"], doc.relative_path)
          end
        end
      end

      # Notes that a page used an asset (a Source or a Reference); returns
      # the page's key.
      def record(page, item)
        key = page_key(page)
        (@page_assets[key] ||= Set.new.compare_by_identity) << item if key
        key
      end

      # What the page map stores for a page's assets:
      #   ["o", logical path, path]                       an original
      #   ["d", path, logical path, canonical transform]  a derivative
      # where path is relative to the asset destination.
      def page_entries(items)
        return [] unless items

        items.map do |item|
          if item.is_a?(Source)
            ["o", item.logical_path, item.digest_path]
          else
            ["d", item.path, item.logical_path, item.transform.canonical]
          end
        end.sort
      end

      # Uses again the assets a page used when it was last rendered.
      def restore(key)
        entries = store.page_assets(key)
        return @page_map_incomplete = true unless entries.is_a?(Array)

        entries.each do |entry|
          restored = case entry
                     in ["o", String => logical_path, String => path]
                       restore_original(logical_path, path)
                     in ["d", String => path, String => logical_path, String => canonical]
                       restore_derivative(path, logical_path, canonical)
                     else false
                     end
          @page_map_incomplete = true unless restored
        end
      end

      def restore_original(logical_path, path)
        source = lookup(logical_path)
        return false unless source && source.digest_path == path

        use(source)
        true
      rescue Error
        false
      end

      def restore_derivative(path, logical_path, canonical)
        match = DERIVATIVE_PATH.match(path)
        return false unless match

        dkey, ext = match.captures
        object = store.object_path(dkey, ext)
        return false unless File.file?(object)

        store.use(dkey)
        dest_path = config.dest_path_for(path)
        return true if @used.key?(dest_path)

        @used[dest_path] = Restored.new(path: path, url: config.url_for(path), logical_path: logical_path,
                                        canonical: canonical, dkey: dkey, ext: ext)
        site.static_files << DerivativeFile.new(site, dest_path, object) if @write_files
        true
      end

      def summary(gc_result)
        text = format("%<derivatives>d derivatives (%<cached>d cached, " \
                      "%<processed>d processed in %<seconds>.1fs), %<originals>d originals", stats)
        return text unless gc_result&.removed&.positive?

        text + format(", removed %<count>d unused cached images (%<mb>.1f MB)",
                      count: gc_result.removed, mb: gc_result.bytes / 1_048_576.0)
      end

      # Translated pages and IndexNow key text by asset URLs with their
      # digest taken out; a URL they can't parse makes them see new text.
      # jekyll-assets served such names, so this only warns.
      def warn_outside_grammar(path, url, filename)
        return if DIGESTED_PATH.match?(path)

        Jekyll.logger.warn("jekyll-magik:", "#{url} (#{filename}) isn't of the form " \
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
