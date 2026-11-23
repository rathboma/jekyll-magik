# frozen_string_literal: true

require "etc"

module Jekyll
  module Magik
    # The plugin's configuration: the jekyll-assets keys under `assets:` that
    # jekyll-magik honours, and its own options under `magik:`.
    class Config
      # jekyll-assets' default source directories, in its order.
      DIRECTORIES = %w(css fonts images videos audios components javascript video audio image img js).freeze
      DEFAULT_SOURCES = (
        DIRECTORIES.map { |d| "assets/#{d}" } |
        DIRECTORIES |
        DIRECTORIES.map { |d| "_assets/#{d}" }
      ).freeze

      DEFAULT_CACHE_DIR = ".jekyll-cache/magik"
      DEFAULT_GC_MAX_AGE_DAYS = 14
      DEFAULT_JPEG_QUALITY = 82
      DEFAULT_WEBP_QUALITY = 75

      MAGIK_KEYS = %w(cache_dir workers gc jpeg_quality webp_quality derivative_integrity manifest).freeze

      # `assets:` keys that would change output if set, which jekyll-magik
      # can't do. Each test returns true when the value asks for that.
      UNSUPPORTED_ASSETS = {
        "digest" => ->(v) { v == false },
        "digest_algorithm" => ->(v) { !v.nil? && v.to_s != "sha512" },
        "full_url" => ->(v) { v == true },
        "cdn" => ->(v) { v.is_a?(Hash) ? !blank?(v["url"]) : !blank?(v) },
        "precompile" => ->(v) { !Array(v).empty? },
        "raw_precompile" => ->(v) { !Array(v).empty? },
        "gzip" => ->(v) { v == true }
      }.freeze

      attr_reader :source, :sources, :load_paths, :destination, :baseurl, :img_integrity,
                  :cache_dir, :workers, :gc_max_age_days, :jpeg_quality, :webp_quality,
                  :derivative_integrity, :manifest, :warnings

      def self.blank?(value)
        value.nil? || value == false || value.to_s.empty?
      end

      # config: the site's configuration hash. env: JEKYLL_ENV, which decides
      # jekyll-assets' default for `integrity` (on in production).
      def initialize(config, env: Jekyll.env)
        @source = File.expand_path(config["source"] || Dir.pwd)
        @warnings = []
        assets = hash_option(config, "assets")
        magik = hash_option(config, "magik")

        read_assets(assets, env)
        read_magik(magik)
        # jekyll-assets prefers `baseurl_root` when it's set.
        @baseurl = strip_slashes(config.key?("baseurl_root") ? config["baseurl_root"] : config["baseurl"])
        freeze
      end

      # The URL of a path under the asset destination, the way jekyll-assets'
      # `prefix_url` builds it: baseurl, destination, path, with one leading
      # slash.
      def url_for(path)
        url = File.join([baseurl, destination, path].compact)
        url.start_with?("/") ? url : "/#{url}"
      end

      # A path under the asset destination, relative to the site's
      # destination directory.
      def dest_path_for(path)
        File.join([destination, path].compact)
      end

      # The cache directory relative to the site source, when it's inside it.
      def relative_cache_dir
        prefix = File.join(source, "")
        cache_dir.start_with?(prefix) ? cache_dir.delete_prefix(prefix) : nil
      end

      private

      def hash_option(config, key)
        value = config[key]
        return {} if value.nil?
        unless value.is_a?(Hash)
          raise ConfigError,
                "`#{key}:` in _config.yml must be a hash, not #{value.inspect}"
        end

        value
      end

      def read_assets(assets, env)
        @sources = (Array(assets["sources"]).map(&:to_s) | DEFAULT_SOURCES).freeze
        @load_paths = @sources.map { |s| File.expand_path(s, source) }.uniq.freeze
        @destination = strip_slashes(assets.key?("destination") ? assets["destination"].to_s : "/assets")
        @img_integrity = read_img_defaults(assets["defaults"], env)

        assets.each do |key, value|
          next if %w(sources destination defaults).include?(key)

          test = UNSUPPORTED_ASSETS[key]
          if test&.call(value)
            raise NotSupported,
                  "`assets: #{key}: #{value.inspect}` in _config.yml isn't supported by jekyll-magik"
          end

          @warnings << "`assets: #{key}` in _config.yml is ignored" unless test
        end
      end

      def read_img_defaults(defaults, env)
        return env == "production" if defaults.nil?
        raise ConfigError, "`assets: defaults:` must be a hash" unless defaults.is_a?(Hash)

        defaults.each_key do |type|
          @warnings << "`assets: defaults: #{type}` in _config.yml is ignored" unless type.to_s == "img"
        end
        img = defaults["img"] || {}
        raise ConfigError, "`assets: defaults: img:` must be a hash" unless img.is_a?(Hash)

        img.each do |key, value|
          case key.to_s
          when "integrity" then next
          when "width", "height"
            next unless value

            raise NotSupported, "`assets: defaults: img: #{key}: #{value.inspect}` in _config.yml " \
                                "isn't supported by jekyll-magik"
          else
            @warnings << "`assets: defaults: img: #{key}` in _config.yml is ignored"
          end
        end
        if img.key?("integrity")
          img["integrity"] ? true : false
        else
          env == "production"
        end
      end

      def read_magik(magik)
        (magik.keys.map(&:to_s) - MAGIK_KEYS).each do |key|
          @warnings << "unknown option `magik: #{key}` in _config.yml"
        end
        @cache_dir = File.expand_path(string_option(magik, "cache_dir", DEFAULT_CACHE_DIR), source)
        @workers = integer_option(magik, "workers", [Etc.nprocessors - 1, 1].max, 0..1024)
        @gc_max_age_days = read_gc(magik["gc"])
        @jpeg_quality = integer_option(magik, "jpeg_quality", DEFAULT_JPEG_QUALITY, 1..100)
        @webp_quality = integer_option(magik, "webp_quality", DEFAULT_WEBP_QUALITY, 1..100)
        @derivative_integrity = boolean_option(magik, "derivative_integrity", false)
        @manifest = boolean_option(magik, "manifest", false)
      end

      def read_gc(value)
        case value
        when nil, true then DEFAULT_GC_MAX_AGE_DAYS
        when false then nil
        when Hash
          (value.keys.map(&:to_s) - %w(max_age_days)).each do |key|
            @warnings << "unknown option `magik: gc: #{key}` in _config.yml"
          end
          days = value.fetch("max_age_days", DEFAULT_GC_MAX_AGE_DAYS)
          return nil if days == false
          return days if days.is_a?(Integer) && days.positive?

          raise ConfigError,
                "`magik: gc: max_age_days:` must be a positive integer or false, not #{days.inspect}"
        else
          raise ConfigError, "`magik: gc:` must be false or a hash with `max_age_days`, not #{value.inspect}"
        end
      end

      def string_option(hash, key, default)
        return default unless hash.key?(key)
        return hash[key] if hash[key].is_a?(String) && !hash[key].empty?

        raise ConfigError, "`magik: #{key}:` must be a non-empty string, not #{hash[key].inspect}"
      end

      def integer_option(hash, key, default, range)
        return default unless hash.key?(key)
        return hash[key] if hash[key].is_a?(Integer) && range.cover?(hash[key])

        raise ConfigError, "`magik: #{key}:` must be an integer from #{range.min} to #{range.max}, " \
                           "not #{hash[key].inspect}"
      end

      def boolean_option(hash, key, default)
        return default unless hash.key?(key)
        return hash[key] if [true, false].include?(hash[key])

        raise ConfigError, "`magik: #{key}:` must be true or false, not #{hash[key].inspect}"
      end

      # jekyll-assets' Utils.strip_slashes: one leading and one trailing slash,
      # and nil for an empty value.
      def strip_slashes(path)
        return nil if path.nil? || path == ""

        path.to_s.gsub(%r{^/|/$}, "")
      end

      def blank?(value)
        self.class.blank?(value)
      end
    end
  end
end
