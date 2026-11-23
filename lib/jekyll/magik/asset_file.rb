# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Jekyll
  module Magik
    # An asset in _site, registered with Jekyll as a static file the first
    # time a build uses it, and written in Jekyll's write phase.
    #
    # Originals are copied, never hardlinked: a tool that rewrites files in
    # _site mustn't be able to edit a source in git. The copy goes to a temp
    # file that is renamed over the destination, so nothing is ever written in
    # place, and it keeps the source's mtime so that the next build can skip
    # a destination that is already this file.
    class AssetFile < Jekyll::StaticFile
      attr_reader :source

      def initialize(site, source)
        @source = source
        @dest_rel = source.dest_path.delete_prefix("/")
        super(site, site.source, File.dirname(@dest_rel), File.basename(@dest_rel))
        @relative_path = relative_source_path
      end

      # The file it's copied from.
      def path
        source.filename
      end

      # Its URL path without the baseurl, like any Jekyll static file.
      def url
        "/#{@dest_rel}"
      end

      def destination(dest)
        @destination ||= {}
        @destination[dest] ||= @site.in_dest_dir(dest, @dest_rel)
      end

      def modified_time
        source.mtime
      end

      def write(dest)
        dest_path = destination(dest)
        return false if up_to_date?(dest_path)

        FileUtils.mkdir_p(File.dirname(dest_path))
        tmp = File.join(File.dirname(dest_path), ".magik-#{SecureRandom.hex(8)}.tmp")
        begin
          IO.copy_stream(source.filename, tmp)
          File.utime(source.stat.atime, source.mtime, tmp)
          File.rename(tmp, dest_path)
        ensure
          FileUtils.rm_f(tmp)
        end
        true
      end

      private

      # The destination is a copy of this source already: a regular file of
      # the same size and mtime that isn't the source itself (a hardlink to it
      # is replaced by a copy). Its name has the content's digest in it.
      def up_to_date?(dest_path)
        dest = File.lstat(dest_path)
        src = source.stat
        dest.file? && dest.size == src.size && dest.mtime == src.mtime &&
          !(dest.ino == src.ino && dest.dev == src.dev)
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def relative_source_path
        prefix = File.join(@site.source, "")
        source.filename.start_with?(prefix) ? source.filename.delete_prefix(prefix) : source.filename
      end
    end
  end
end
