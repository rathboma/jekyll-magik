# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Jekyll
  module Magik
    # A file jekyll-magik writes to _site, registered with Jekyll as a static
    # file the first time a build uses it, and written in Jekyll's write
    # phase. The destination is always replaced by renaming a temp file over
    # it, never written in place.
    module OutputFile
      # Its URL path without the baseurl, like any Jekyll static file.
      def url
        "/#{@dest_rel}"
      end

      def destination(dest)
        @destination ||= {}
        @destination[dest] ||= @site.in_dest_dir(dest, @dest_rel)
      end

      private

      # Yields a temp path next to the destination, then renames it over the
      # destination.
      def replace(dest_path)
        FileUtils.mkdir_p(File.dirname(dest_path))
        tmp = File.join(File.dirname(dest_path), ".magik-#{SecureRandom.hex(8)}.tmp")
        yield tmp
        File.rename(tmp, dest_path)
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def relative_to_source(path)
        prefix = File.join(@site.source, "")
        path.start_with?(prefix) ? path.delete_prefix(prefix) : path
      end
    end

    # An original: a source file used as it is.
    #
    # Originals are copied, never hardlinked: a tool that rewrites files in
    # _site mustn't be able to edit a source in git. The copy keeps the
    # source's mtime so that the next build can skip a destination that is
    # already this file.
    class AssetFile < Jekyll::StaticFile
      include OutputFile

      attr_reader :source

      def initialize(site, source)
        @source = source
        @dest_rel = source.dest_path.delete_prefix("/")
        super(site, site.source, File.dirname(@dest_rel), File.basename(@dest_rel))
        @relative_path = relative_to_source(source.filename)
      end

      # The file it's copied from.
      def path
        source.filename
      end

      def modified_time
        source.mtime
      end

      def write(dest)
        dest_path = destination(dest)
        return false if up_to_date?(dest_path)

        replace(dest_path) do |tmp|
          check_unchanged!
          IO.copy_stream(source.filename, tmp)
          check_unchanged!
          File.utime(source.stat.atime, source.mtime, tmp)
        end
        true
      end

      private

      # The destination is a copy of this source already: a regular file of
      # the same size and mtime that isn't the source itself (a hardlink to it
      # is replaced by a copy). Its name has the content's digest in it.
      def up_to_date?(dest_path)
        dest = lstat(dest_path)
        src = source.stat
        dest&.file? && dest.size == src.size && dest.mtime == src.mtime &&
          !(dest.ino == src.ino && dest.dev == src.dev)
      end

      # The file's name and integrity come from its digest, taken when a page
      # first used it. If it was saved since (during `jekyll serve`), its new
      # bytes mustn't go out under the old name: fail, and the rebuild the
      # save triggers writes it under its new one.
      def check_unchanged!
        now = File.stat(source.filename)
        was = source.stat
        return if now.size == was.size && now.mtime == was.mtime && now.ino == was.ino

        raise Error, "#{source.filename} changed during the build; build again"
      end
    end

    # A derivative: an object from the Store, hardlinked into _site. Objects
    # are read-only and never change once written (their name is their
    # content key), so a destination that is the object's inode is up to
    # date. Where hardlinks can't be made (the cache on another filesystem)
    # it's copied, with the object's mtime.
    class DerivativeFile < Jekyll::StaticFile
      include OutputFile

      attr_reader :object_path

      # dest_path: relative to the site's destination. object_path: the
      # object in the Store.
      def initialize(site, dest_path, object_path)
        @dest_rel = dest_path.delete_prefix("/")
        @object_path = object_path
        super(site, site.source, File.dirname(@dest_rel), File.basename(@dest_rel))
        @relative_path = relative_to_source(object_path)
      end

      def path
        object_path
      end

      def modified_time
        @modified_time ||= object_stat&.mtime || Time.at(0)
      end

      def write(dest)
        dest_path = destination(dest)
        object = object_stat
        unless object
          raise Error,
                "the cached image for #{url} (#{object_path}) was removed during the build; build again"
        end
        return false if up_to_date?(dest_path, object)

        replace(dest_path) do |tmp|
          File.link(object_path, tmp)
        rescue Errno::EXDEV, Errno::EPERM, Errno::EMLINK, Errno::ENOTSUP, NotImplementedError
          IO.copy_stream(object_path, tmp)
          File.utime(object.atime, object.mtime, tmp)
        end
        true
      end

      private

      def object_stat
        File.stat(object_path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      # The object itself, or a copy of it (same size and mtime).
      def up_to_date?(dest_path, object)
        dest = lstat(dest_path)
        return false unless dest&.file?

        (dest.ino == object.ino && dest.dev == object.dev) ||
          (dest.size == object.size && dest.mtime == object.mtime)
      end
    end
  end
end
