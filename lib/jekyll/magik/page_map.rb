# frozen_string_literal: true

require "json"

module Jekyll
  module Magik
    # The page map's side of Api: what a page's assets are recorded as, and
    # how an incremental build uses again the assets of a page it skips, so
    # Jekyll's cleaner keeps them (Api#after_render).
    module PageMap
      DERIVATIVE_PATH = /-(\h{64})\.([a-z0-9]+)\z/

      # A derivative an incremental build kept for a page it didn't render.
      Restored = Struct.new(:path, :url, :logical_path, :canonical, :dkey, :ext, keyword_init: true)

      private

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
                       restore_derivative(key, path, logical_path, canonical)
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

      def restore_derivative(page, path, logical_path, canonical)
        match = DERIVATIVE_PATH.match(path)
        return false unless match

        dkey, ext = match.captures
        return rederive(page, path, logical_path, canonical) unless store.intact?(dkey, ext)

        object = store.object_path(dkey, ext)
        store.use(dkey)
        dest_path = config.dest_path_for(path)
        return true if @used.key?(dest_path)

        @used[dest_path] = Restored.new(path: path, url: config.url_for(path), logical_path: logical_path,
                                        canonical: canonical, dkey: dkey, ext: ext)
        site.static_files << DerivativeFile.new(site, dest_path, object) if @write_files
        true
      end

      # A restored derivative whose object is missing or damaged, made again
      # from its source and transform, if that gives the URL the skipped page
      # has (its source hasn't changed). Failing to make it fails the build,
      # as it would in a tag.
      def rederive(page, path, logical_path, canonical)
        return false unless same_path?(path, logical_path, canonical)

        derive(lookup(logical_path), Transform.from_h(JSON.parse(canonical)))
        true
      rescue Error => e
        relative = page.delete_prefix(File.join(site.source, ""))
        raise e.class,
              "#{e.message} (remaking an image of #{relative}, which this incremental build didn't render)"
      end

      # Whether the source and transform recorded for a derivative still
      # give its path: else the source changed (or isn't there), and the
      # skipped page's URL can't be made again.
      def same_path?(path, logical_path, canonical)
        source = lookup(logical_path)
        transform = Transform.from_h(JSON.parse(canonical))
        source && transform ? registry.path_for(source, transform) == path : false
      rescue Error, JSON::ParserError, SystemCallError
        false
      end
    end
  end
end
