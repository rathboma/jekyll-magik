# frozen_string_literal: true

require "digest"
require "fastimage"
require "fileutils"
require "json"
require "securerandom"
require "set"

module Jekyll
  module Magik
    # The global cache of processed images, shared by every build that uses
    # the same `cache_dir`:
    #
    #   <cache_dir>/v1/objects/<dkey[0,2]>/<dkey>.<ext>   the images, read-only
    #   <cache_dir>/v1/index.json     dkey => {ext, bytes, width, height, sha512, last_used_at}
    #   <cache_dir>/v1/sources.json   source memo: path => {size, mtime_ns, ctime_ns, inode,
    #                                 sha512, width, height, type}
    #   <cache_dir>/v1/pages.json     page path => the assets it used
    #
    # `v1` is the format: a new format starts a new directory.
    #
    # The JSON files only speed things up. An object with no index entry is
    # valid (its size is read from the file); an entry whose object is
    # missing, or has another size, is a miss. Objects are written to a temp
    # file and renamed into place, so one that exists is complete.
    #
    # A Store is loaded once per process and kept across `jekyll serve`
    # regenerations. `save` merges with what's on disk under an flock, so
    # concurrent builds don't lose each other's entries. Nothing here clears
    # the cache: only GC, at the end of a full build, removes objects, and
    # only ones unused for `gc.max_age_days`.
    class Store
      FORMAT = "v1"
      TMP_PREFIX = ".tmp-"
      # Temp files older than this are left over from a killed worker.
      STALE_TMP_SECONDS = 3600
      DAY = 86_400

      GcResult = Struct.new(:removed, :bytes)

      attr_reader :root, :objects_dir

      def initialize(cache_dir)
        @root = File.join(cache_dir, FORMAT)
        @objects_dir = File.join(@root, "objects")
        @index = read_json("index.json")
        @sources = read_json("sources.json")
        @pages = read_json("pages.json")
        reset!
      end

      # A new build.
      def reset!
        @used = Set.new
        @checked = Set.new
        @sources_seen = Set.new
        @source_updates = {}
        @page_updates = {}
      end

      def object_path(dkey, ext)
        File.join(objects_dir, dkey[0, 2], "#{dkey}.#{ext}")
      end

      # The index entry for an object that is in the cache with the expected
      # size, or nil. Drops an entry that no longer matches its object, and
      # adds one for an object that has none.
      def fetch(dkey, ext, width, height)
        path = object_path(dkey, ext)
        stat = file_stat(path)
        entry = @index[dkey]
        if entry
          if stat && stat.size == entry["bytes"] &&
             entry.values_at("ext", "width", "height") == [ext, width, height]
            @checked << dkey
            return entry
          end

          @index.delete(dkey)
        end
        return nil unless stat&.size&.positive? && image_size(path) == [width, height] &&
                          complete?(path, ext, stat.size)

        @checked << dkey
        @index[dkey] = { "ext" => ext, "bytes" => stat.size, "width" => width, "height" => height }
      end

      # Records an object a worker has just written.
      def record(dkey, ext:, bytes:, width:, height:)
        @checked << dkey
        @index[dkey] = { "ext" => ext, "bytes" => bytes, "width" => width, "height" => height }
      end

      def entry(dkey)
        @index[dkey]
      end

      # The object's SHA-512 (hex), read once and kept in its entry.
      def sha512(dkey)
        entry = @index.fetch(dkey) { raise Error, "#{dkey} isn't in the cache" }
        entry["sha512"] ||= Digest::SHA512.file(object_path(dkey, entry["ext"])).hexdigest
      end

      # Marks an object used in this build: GC keeps it and its last use is
      # now.
      def use(dkey)
        @used << dkey
      end

      def used?(dkey)
        @used.include?(dkey)
      end

      # What the memo holds for a file, if the file hasn't changed since:
      # same size, mtime, ctime and inode.
      def source_info(filename, stat)
        @sources_seen << filename
        info = @sources[filename]
        return nil unless info

        info if info["size"] == stat.size && info["inode"] == stat.ino &&
                info["mtime_ns"] == nanoseconds(stat.mtime) && info["ctime_ns"] == nanoseconds(stat.ctime)
      end

      # Adds what was read from a file (sha512, width, height, type) to the
      # memo.
      def remember_source(filename, stat, fields)
        info = source_info(filename, stat)
        info = info ? info.merge(fields) : source_stat(stat).merge(fields)
        @sources[filename] = @source_updates[filename] = info
      end

      # The assets a page used when it was last rendered, or nil if it
      # isn't known.
      def page_assets(page)
        @pages[page]
      end

      # Records the assets a page used in this build.
      def update_page(page, assets)
        @pages[page] = @page_updates[page] = assets
      end

      # Writes the index, the memo and the page map, merged with what other
      # processes saved since this one loaded them. With `full_build`, also
      # drops this site's memo entries and pages that this build didn't see
      # and, with `gc_max_age_days`, runs GC. Returns the GC result (or nil).
      def save(full_build:, site_source:, live_pages: nil, gc_max_age_days: nil, now: Time.now.to_i)
        return nil if nothing_to_save?

        FileUtils.mkdir_p(root)
        locked do
          index = merge_index(read_json("index.json"), now)
          sources = read_json("sources.json").merge(@source_updates)
          pages = read_json("pages.json").merge(@page_updates)
          result = nil
          if full_build
            result = gc(index, gc_max_age_days, now) if gc_max_age_days
            prune(sources, site_source) { |path| @sources_seen.include?(path) }
            prune(pages, site_source) { |path| live_pages.include?(path) } if live_pages
            # Other checkouts' entries, once their files are gone.
            sources.select! { |path, _| File.exist?(path) }
            pages.select! { |path, _| File.exist?(path) || live_pages&.include?(path) }
          end
          write_json("index.json", index)
          write_json("sources.json", sources)
          write_json("pages.json", pages)
          @index = index
          @sources = sources
          @pages = pages
          result
        end
      rescue SystemCallError => e
        Jekyll.logger.warn("jekyll-magik:", "couldn't save the cache in #{root}: #{e.message}")
        nil
      end

      private

      def nothing_to_save?
        !File.directory?(root) && @index.empty? && @source_updates.empty? &&
          @page_updates.values.all?(&:empty?)
      end

      def locked
        File.open(File.join(root, "lock"), File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      # What's on disk, with the entries this process checked against their
      # objects in this build (the rest it only loaded, and disk may know
      # better), keeping a known sha512. Everything this build used was last
      # used now.
      def merge_index(disk, now)
        merged = disk.merge(@index.slice(*@checked)) do |_dkey, theirs, ours|
          if !ours["sha512"] && theirs["sha512"] && theirs["bytes"] == ours["bytes"]
            ours.merge("sha512" => theirs["sha512"])
          else
            ours
          end
        end
        @used.each do |dkey|
          entry = merged[dkey] || @index[dkey]
          merged[dkey] = entry.merge("last_used_at" => [entry["last_used_at"].to_i, now].max) if entry
        end
        merged
      end

      # Whether an object without an index entry is whole: the formats'
      # own ends (PNG's IEND chunk, JPEG's EOI marker, WebP's RIFF length),
      # since FastImage only reads the header.
      def complete?(path, ext, size)
        File.open(path, "rb") do |file|
          case ext
          when "png"
            file.seek(-12, IO::SEEK_END)
            file.read(12) == "\0\0\0\0IEND\xAEB`\x82".b
          when "jpg"
            file.seek(-2, IO::SEEK_END)
            file.read(2) == "\xFF\xD9".b
          when "webp"
            header = file.read(12)
            header.start_with?("RIFF") && header.byteslice(8, 4) == "WEBP" &&
              header.byteslice(4, 4).unpack1("V") + 8 == size
          else false
          end
        end
      rescue SystemCallError, NoMethodError
        false
      end

      # Removes objects this build didn't use whose last use (or, with no
      # entry, whose mtime) is older than max_age_days, entries whose object
      # is gone, temp files a killed worker left and empty directories.
      def gc(index, max_age_days, now)
        cutoff = now - (max_age_days * DAY)
        result = GcResult.new(0, 0)
        present = {}
        Dir.glob(File.join(objects_dir, "*", "*")).each do |path|
          dkey, ext = File.basename(path).split(".", 2)
          stat = file_stat(path) or next
          last_used = index.dig(dkey, "last_used_at") || stat.mtime.to_i
          if !@used.include?(dkey) && last_used < cutoff
            next unless remove(path)

            result.removed += 1
            result.bytes += stat.size
          else
            present[dkey] = ext
          end
        end
        index.select! { |dkey, entry| present[dkey] == entry["ext"] }
        sweep_temp_files(now)
        result
      end

      def sweep_temp_files(now)
        Dir.glob(File.join(objects_dir, "#{TMP_PREFIX}*")).each do |path|
          stat = file_stat(path)
          remove(path) if stat && stat.mtime.to_i < now - STALE_TMP_SECONDS
        end
        Dir.glob(File.join(objects_dir, "*/")).each do |dir|
          Dir.rmdir(dir)
        rescue SystemCallError
          nil
        end
      end

      def prune(hash, site_source)
        prefix = File.join(site_source, "")
        hash.reject! { |path, _| path.start_with?(prefix) && !yield(path) }
      end

      def remove(path)
        File.unlink(path)
        true
      rescue Errno::ENOENT
        false
      end

      def read_json(name)
        data = JSON.parse(File.read(File.join(root, name)))
        data.is_a?(Hash) ? data : {}
      rescue Errno::ENOENT, Errno::ENOTDIR
        {}
      rescue JSON::ParserError, EncodingError => e
        Jekyll.logger.warn("jekyll-magik:",
                           "ignoring #{File.join(root, name)}, which can't be read (#{e.class})")
        {}
      end

      # Temp file and rename, keys in order, so the file is always whole
      # and the same data gives the same bytes.
      def write_json(name, data)
        path = File.join(root, name)
        tmp = File.join(root, ".#{name}.#{SecureRandom.hex(6)}.tmp")
        File.write(tmp, JSON.generate(data.sort.to_h))
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def file_stat(path)
        stat = File.stat(path)
        stat.file? ? stat : nil
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def image_size(path)
        FastImage.size(path)
      rescue StandardError
        nil
      end

      def source_stat(stat)
        { "size" => stat.size, "mtime_ns" => nanoseconds(stat.mtime), "ctime_ns" => nanoseconds(stat.ctime),
          "inode" => stat.ino }
      end

      def nanoseconds(time)
        (time.to_i * 1_000_000_000) + time.nsec
      end
    end
  end
end
