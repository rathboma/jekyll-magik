# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "set"

module Jekyll
  module Magik
    # One build's derivatives: the resized and converted images its tags
    # refer to.
    #
    # Two keys come from a derivative's inputs, never from its bytes:
    #
    # - dkey, the content key: sha256 of the source's sha512, the canonical
    #   transform, the output settings and PIPELINE_VERSION (64 hex). The
    #   output settings are the format it's written in and the config value
    #   it falls back on for quality (`jpeg_quality` or `webp_quality`, when
    #   the tag gives no `quality`). Equal dkeys mean equal bytes, so the
    #   Store keeps one object per dkey.
    # - tkey, the stem key: sha256 of the source's logical path and the
    #   canonical transform, cut to 10 hex. It doesn't change when the
    #   source's content does, and differs for each width of a srcset.
    #
    # A derivative's URL is
    #
    #   <baseurl>/<destination>/<logical path minus ext>-<tkey>-<dkey>.<ext>
    #
    # which keeps the image's name, matches the digest grammar beekeeper's
    # translation Worker uses (a stable stem, a 64-hex digest) and can't
    # collide with an original's URL (those end in 128 hex).
    #
    # The first reference to a derivative in a build looks it up in the
    # Store, and processes it if it's missing; every later one is a hash
    # lookup. Only the render thread uses a Registry, so plain Hashes do.
    class Registry
      TKEY_LENGTH = 10

      # A processed image: one per dkey. Several References (the same pixels
      # from sources with the same content) can share one.
      class Derivative
        attr_reader :dkey, :ext, :source, :transform, :quality, :width, :height, :pages
        attr_accessor :state, :bytes, :error

        def initialize(dkey:, ext:, source:, transform:, quality:, width:, height:)
          @dkey = dkey
          @ext = ext
          @source = source
          @transform = transform
          @quality = quality
          @width = width
          @height = height
          @pages = Set.new
          # nil until first used in the build, then :cached (found in the
          # Store), :queued, :done (processed) or :failed.
          @state = nil
        end

        def inspect
          "#<#{self.class.name} #{source.logical_path} #{transform.canonical} #{dkey[0, 12]} #{state}>"
        end
      end

      # A derivative's URL: a source's logical path and a transform. `path`
      # is relative to the asset destination.
      Reference = Struct.new(:derivative, :logical_path, :transform, :tkey, :path, :url, :dest_path,
                             keyword_init: true) do
        def dkey = derivative.dkey
        def ext = derivative.ext
        def width = derivative.width
        def height = derivative.height
      end

      Stats = Struct.new(:references, :cached, :processed, :seconds)

      attr_reader :config, :store, :processor, :stats

      def self.dkey(source_digest, transform, settings)
        payload = [PIPELINE_VERSION, source_digest, transform.canonical, settings]
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def self.tkey(logical_path, transform)
        Digest::SHA256.hexdigest(JSON.generate([logical_path, transform.canonical]))[0, TKEY_LENGTH]
      end

      def initialize(config:, store:, processor:)
        @config = config
        @store = store
        @processor = processor
        @references = {}
        @derivatives = {}
        @stats = Stats.new(0, 0, 0, 0.0)
      end

      # The Reference for a source and a transform, with its derivative in
      # the Store: found there, or processed now. Raises if it can't be.
      def reference(source, transform)
        @stats.references += 1
        ref = (@references[[source, transform]] ||= build(source, transform))
        ready(ref.derivative)
        ref
      end

      # The Reference's path, without making sure the image is in the Store.
      def path_for(source, transform)
        (@references[[source, transform]] ||= build(source, transform)).path
      end

      def references
        @references.values
      end

      def derivatives
        @derivatives.values
      end

      # Subresource integrity of a derivative's bytes, as sprockets writes it.
      def integrity(derivative)
        "sha512-#{[[store.sha512(derivative.dkey)].pack("H*")].pack("m0")}"
      end

      private

      def build(source, transform)
        ext = transform.output_format(source)
        quality, settings = output_settings(transform, ext, source)
        width, height = transform.output_size(*source.dimensions)
        dkey = self.class.dkey(source.digest, transform, settings)
        derivative = @derivatives[dkey] ||= Derivative.new(
          dkey: dkey, ext: ext, source: source, transform: transform, quality: quality,
          width: width, height: height
        )
        tkey = self.class.tkey(source.logical_path, transform)
        path = "#{source.name}-#{tkey}-#{dkey}.#{ext}"
        Reference.new(derivative: derivative, logical_path: source.logical_path, transform: transform,
                      tkey: tkey, path: path, url: config.url_for(path),
                      dest_path: config.dest_path_for(path))
      end

      # The quality the output is encoded with, and the settings that go into
      # dkey: the output format, the config value used when the transform
      # gives no quality, and the EXIF rotation applied. Rotation follows
      # FastImage's reading of the file, which a FastImage release could
      # change (it doesn't read WebP orientation yet): the URL must change
      # with it.
      def output_settings(transform, ext, source)
        settings = { "format" => ext }
        settings["orientation"] = source.orientation if source.orientation > 1
        default = case ext
                  when "jpg" then ["jpeg_quality", config.jpeg_quality]
                  when "webp" then ["webp_quality", config.webp_quality]
                  end
        return [transform.quality, settings] if default.nil? || transform.quality

        settings[default[0]] = default[1]
        [default[1], settings]
      end

      def ready(derivative)
        case derivative.state
        when :cached, :done then return
        when :failed then raise derivative.error
        end

        store.use(derivative.dkey)
        entry = store.fetch(derivative.dkey, derivative.ext, derivative.width, derivative.height)
        if entry
          derivative.bytes = entry["bytes"]
          derivative.state = :cached
          @stats.cached += 1
        else
          process(derivative)
        end
      end

      def process(derivative)
        derivative.state = :queued
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reply = processor.run(job(derivative))
        @stats.seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        check_reply!(derivative, reply)
        store.record(derivative.dkey, ext: derivative.ext, bytes: reply["bytes"],
                                      width: derivative.width, height: derivative.height)
        derivative.bytes = reply["bytes"]
        derivative.state = :done
        @stats.processed += 1
      rescue Error => e
        derivative.state = :failed
        derivative.error = e
        raise
      end

      def job(derivative)
        source = derivative.source
        mtime = source.mtime
        {
          "id" => derivative.dkey,
          "source" => source.filename,
          "source_size" => source.size,
          "source_mtime_ns" => (mtime.to_i * 1_000_000_000) + mtime.nsec,
          "source_width" => source.width,
          "source_height" => source.height,
          "autorotate" => source.orientation > 1,
          "steps" => derivative.transform.steps(*source.dimensions),
          "format" => derivative.ext,
          "quality" => derivative.quality,
          "tmp" => File.join(store.objects_dir, "#{Store::TMP_PREFIX}#{SecureRandom.hex(8)}"),
          "output" => store.object_path(derivative.dkey, derivative.ext)
        }
      end

      def check_reply!(derivative, reply)
        source = derivative.source
        what = "#{source.logical_path} (#{source.filename}) with #{derivative.transform}"
        raise Error, "can't resize #{what}: #{reply["error"]}" unless reply["ok"]

        size = [reply["width"], reply["height"]]
        return if size == [derivative.width, derivative.height]

        # Not a cache object anyone may use: its size isn't the one its URL
        # was given for.
        FileUtils.rm_f(store.object_path(derivative.dkey, derivative.ext))
        raise Error, "resizing #{what} made a #{size.join("x")} image, " \
                     "not the #{derivative.width}x#{derivative.height} expected"
      end
    end
  end
end
