# frozen_string_literal: true

require "digest"
require "fastimage"

module Jekyll
  module Magik
    # A file in the asset load paths, used as it is.
    #
    # Its URL is sprockets 4's `digest_path` (with an empty environment
    # version) under the asset destination:
    #
    #   /assets/<logical path minus ext>-<sha512 hex of the file>.<ext>
    #
    # The digest and the pixel size are read lazily and at most once: a Source
    # lives for one build.
    class Source
      attr_reader :filename, :logical_path, :content_type, :config

      def initialize(filename:, logical_path:, content_type:, config:)
        @filename = filename
        @logical_path = logical_path
        @content_type = content_type
        @config = config
      end

      def stat
        @stat ||= File.stat(filename)
      end

      def size
        stat.size
      end

      def mtime
        stat.mtime
      end

      # The SHA-512 of the file, hex.
      def digest
        @digest ||= Digest::SHA512.file(filename).hexdigest
      end

      # Subresource integrity, as sprockets writes it.
      def integrity
        "sha512-#{[[digest].pack("H*")].pack("m0")}"
      end

      # The logical path with the digest before the extension.
      def digest_path
        @digest_path ||= logical_path.sub(/\.(\w+)\z/) { |ext| "-#{digest}#{ext}" }
      end

      def url
        @url ||= config.url_for(digest_path)
      end

      # Where the file goes, relative to the site's destination directory.
      def dest_path
        @dest_path ||= config.dest_path_for(digest_path)
      end

      def image?
        content_type.start_with?("image/")
      end

      def svg?
        content_type == Mime::SVG
      end

      # [width, height] in pixels, from the file's header.
      def dimensions
        @dimensions ||= begin
          FastImage.size(filename, raise_on_failure: true)
        rescue FastImage::FastImageException => e
          raise Error,
                "can't read the size of #{logical_path} (#{filename}): #{e.class.name.split("::").last}"
        end
      end

      def width
        dimensions[0]
      end

      def height
        dimensions[1]
      end

      def inspect
        "#<#{self.class.name} #{logical_path}>"
      end
    end
  end
end
