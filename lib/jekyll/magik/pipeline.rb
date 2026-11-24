# frozen_string_literal: true

require "fileutils"
require "vips"

module Jekyll
  module Magik
    # The libvips side of a transform: runs one job and writes the image into
    # the cache. Loaded by worker processes (worker.rb), and by Jekyll's own
    # process only with `workers: 0`. Nothing else may require it, because
    # `require "vips"` starts libvips and the Jekyll process must stay
    # fork-safe and able to build without libvips installed (CLAUDE.md, rule
    # 5). It loads nothing of Jekyll's.
    #
    # A job (a Hash from JSON) has:
    #   source, source_size, source_mtime_ns   the image and its stat when it was digested
    #   source_width, source_height            its size as the parent read it (FastImage)
    #   autorotate  whether to turn it upright by its EXIF orientation: when
    #               FastImage did (Source#orientation), which it does for JPEGs
    #   steps     Transform#steps: [["resize", w, h], ["crop", x, y, w, h], ...]
    #   format    "jpg", "png" or "webp"
    #   quality   for jpg and webp
    #   tmp       a temp path in the objects directory, on the same filesystem
    #   output    where the object goes
    #
    # The output is written to `tmp`, made read-only and renamed to `output`,
    # so an object that exists is whole. Metadata is always stripped and no
    # timestamps are written: the same job gives the same bytes.
    #
    # This is the plain version from #2. #3 makes it exact (shrink-on-load
    # with ImageMagick's rounding, colour profiles, palette PNGs, golden
    # tests against ImageMagick); any change to the bytes it writes for an
    # existing transform bumps PIPELINE_VERSION.
    module Pipeline
      # Jobs never share operations, and libvips caches loads by file name:
      # a file changed during `jekyll serve` would come back with its old
      # pixels, to be stored under its new digest.
      Vips.cache_set_max(0)

      module_function

      # Returns { "width", "height", "bytes" } of the object written.
      def run(job)
        check_source!(job)
        check_size!(job)
        image = transform(job)
        tmp = job.fetch("tmp")
        output = job.fetch("output")
        begin
          FileUtils.mkdir_p(File.dirname(tmp))
          save(image, tmp, job.fetch("format"), job["quality"])
          check_source!(job)
          File.chmod(0o444, tmp)
          place(tmp, output)
        ensure
          FileUtils.rm_f(tmp)
        end
        { "width" => image.width, "height" => image.height, "bytes" => File.size(output) }
      end

      # A full build's GC removes empty object directories, maybe just after
      # this made one: make it again once.
      def place(tmp, output)
        FileUtils.mkdir_p(File.dirname(output))
        File.rename(tmp, output)
      rescue Errno::ENOENT
        raise unless File.exist?(tmp)

        FileUtils.mkdir_p(File.dirname(output))
        File.rename(tmp, output)
      end

      def transform(job)
        source = job.fetch("source")
        rotate = job.fetch("autorotate")
        image = nil
        job.fetch("steps").each do |name, *args|
          case name
          when "resize"
            width, height = args
            image = if image
                      # Already upright, if it's to be: load rotated it.
                      image.thumbnail_image(width, height: height, size: :force, no_rotate: true)
                    else
                      # Shrinks on load.
                      Vips::Image.thumbnail(source, width, height: height, size: :force, no_rotate: !rotate)
                    end
          when "crop"
            image = (image || load(source, rotate)).crop(*args)
          else
            raise ArgumentError, "unknown step #{name.inspect}"
          end
        end
        image || load(source, rotate)
      end

      def load(source, rotate)
        image = Vips::Image.new_from_file(source)
        rotate ? image.autorot : image
      end

      # The steps were computed for the size the parent read: libvips must
      # see the same, or a forced resize would squash the image.
      def check_size!(job)
        header = Vips::Image.new_from_file(job.fetch("source"))
        size = [header.width, header.height]
        size.reverse! if job.fetch("autorotate") && orientation(header) >= 5
        expected = [job.fetch("source_width"), job.fetch("source_height")]
        return if size == expected

        raise "libvips reads #{job["source"]} as #{size.join("x")}, not #{expected.join("x")}"
      end

      def orientation(image)
        image.get_typeof("orientation").zero? ? 1 : image.get("orientation").to_i
      end

      def save(image, path, format, quality)
        keep = Vips.at_least_libvips?(8, 15) ? { keep: :none } : { strip: true }
        case format
        when "jpg"
          image = image.flatten(background: [255]) if image.has_alpha?
          image.jpegsave(path, Q: quality, optimize_coding: true, interlace: false, **keep)
        when "webp"
          image.webpsave(path, Q: quality, effort: 4, **keep)
        when "png"
          image.pngsave(path, compression: 6, **keep)
        else
          raise ArgumentError, "unknown format #{format.inspect}"
        end
      end

      # The source's name and URL come from its digest, taken before the
      # job: if it was saved since (during `jekyll serve`), its new pixels
      # mustn't go into the object for the old digest.
      def check_source!(job)
        stat = File.stat(job.fetch("source"))
        mtime_ns = (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec
        return if stat.size == job.fetch("source_size") && mtime_ns == job.fetch("source_mtime_ns")

        raise "#{job["source"]} changed during the build; build again"
      end
    end
  end
end
