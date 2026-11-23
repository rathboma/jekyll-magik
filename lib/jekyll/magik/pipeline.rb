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
      module_function

      # Returns { "width", "height", "bytes" } of the object written.
      def run(job)
        check_source!(job)
        image = transform(job)
        tmp = job.fetch("tmp")
        output = job.fetch("output")
        begin
          FileUtils.mkdir_p(File.dirname(tmp))
          save(image, tmp, job.fetch("format"), job["quality"])
          check_source!(job)
          File.chmod(0o444, tmp)
          FileUtils.mkdir_p(File.dirname(output))
          File.rename(tmp, output)
        ensure
          FileUtils.rm_f(tmp)
        end
        { "width" => image.width, "height" => image.height, "bytes" => File.size(output) }
      end

      def transform(job)
        source = job.fetch("source")
        image = nil
        job.fetch("steps").each do |name, *args|
          case name
          when "resize"
            width, height = args
            image = if image
                      image.thumbnail_image(width, height: height, size: :force)
                    else
                      # Shrinks on load, and turns the image upright by its
                      # EXIF orientation.
                      Vips::Image.thumbnail(source, width, height: height, size: :force)
                    end
          when "crop"
            image = (image || load(source)).crop(*args)
          else
            raise ArgumentError, "unknown step #{name.inspect}"
          end
        end
        image || load(source)
      end

      def load(source)
        Vips::Image.new_from_file(source).autorot
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
