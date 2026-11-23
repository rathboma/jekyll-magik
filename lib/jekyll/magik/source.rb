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
    # lives for one build. With a memo (the Store), they are read from the
    # file only when it changed since a build read them last.
    class Source
      attr_reader :filename, :logical_path, :content_type, :config, :memo

      def initialize(filename:, logical_path:, content_type:, config:, memo: nil)
        @filename = filename
        @logical_path = logical_path
        @content_type = content_type
        @config = config
        @memo = memo
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

      # The SHA-512 of the file, hex. The file's stat is taken first, so that
      # AssetFile can tell if it changed before it was copied.
      def digest
        @digest ||= begin
          stat
          memo&.source_info(filename, stat)&.fetch("sha512", nil) || begin
            hex = Digest::SHA512.file(filename).hexdigest
            memo&.remember_source(filename, stat, "sha512" => hex)
            hex
          end
        end
      end

      # Subresource integrity, as sprockets writes it.
      def integrity
        "sha512-#{[[digest].pack("H*")].pack("m0")}"
      end

      # Names sprockets takes to carry a digest already (`lib-1a2b3c4.digested.js`).
      ALREADY_DIGESTED = /-([0-9a-zA-Z]{7,128})\.digested/

      # The logical path with the digest before the extension, unless the
      # name already has one.
      def digest_path
        @digest_path ||= if name.match?(ALREADY_DIGESTED)
                           logical_path
                         else
                           logical_path.sub(/\.(\w+)\z/) { |ext| "-#{digest}#{ext}" }
                         end
      end

      # The logical path without its extension, sprockets' `name`.
      def name
        logical_path.delete_suffix(Mime.extname(logical_path)&.first.to_s)
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

      # [width, height] in pixels, from the file's header. A JPEG's are after
      # its EXIF rotation.
      def dimensions
        header.first(2)
      end

      # The EXIF orientation FastImage applied to `dimensions` (1 when it
      # applied none). FastImage reads it from the content, for JPEGs (and
      # TIFFs) only, so a transform rotates exactly the images whose size it
      # predicted upright.
      def orientation
        header[2]
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

      private

      # [width, height, orientation], from the memo or the file's header.
      def header
        @header ||= begin
          info = memo&.source_info(filename, stat)
          info&.key?("orientation") ? info.values_at("width", "height", "orientation").freeze : read_header
        end
      end

      def read_header
        image = FastImage.new(filename, raise_on_failure: true)
        width, height = image.size
        orientation = image.orientation || 1
        memo&.remember_source(filename, stat, "width" => width, "height" => height,
                                              "orientation" => orientation, "type" => image.type.to_s)
        [width, height, orientation].freeze
      rescue FastImage::FastImageException => e
        raise Error,
              "can't read the size of #{logical_path} (#{filename}): #{e.class.name.split("::").last}"
      end
    end
  end
end
