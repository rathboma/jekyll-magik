# frozen_string_literal: true

# Loaded into a jekyll-assets build of beekeeper-studio/web by bench/originals
# (with --plugins). It runs jekyll-magik next to jekyll-assets, in the same
# process and Liquid contexts, and compares what each produces for files used
# as they are:
#
# - tags: every {% asset %} render without `magick:` args, rendered by both
#   with the same Liquid context. <img> markup and @path URLs must be
#   byte-identical; @inline SVG is jekyll-magik's own (see Svg)
# - Ruby API: seo-assets.rb's digest_path (og:image, JSON-LD) against
#   site.magik's URL, and image_size.rb against asset_size
# - the manifest: every original in jekyll-assets' sprockets manifest
#   resolves to the same digest path, integrity and URL grammar
# - with MAGIK_COMPARE_DERIVATIVES=1, every {% asset %} render with `magick:`
#   args too: jekyll-magik processes each derivative (in its worker, into
#   $MAGIK_COMPARE_CACHE, default a temp dir that later runs reuse), its
#   <img> must match jekyll-assets' apart from src and integrity, and its
#   pixel size must be the size of jekyll-assets' ImageMagick output
#
# Writes a JSON report to $MAGIK_COMPARE_REPORT and prints a summary.

require "json"
require "tmpdir"
require_relative "../../lib/jekyll/magik/core"

module MagikCompare
  DIGESTED = %r{/assets/[\w./-]+?-(?:[0-9a-f]{64,128}|[0-9A-Z]{8})\.[a-z0-9]+}
  MAX_EXAMPLES = 25

  class << self
    attr_reader :report

    def derivatives?
      ENV["MAGIK_COMPARE_DERIVATIVES"] == "1"
    end

    def reset!(site)
      @site = site
      cache = ENV.fetch("MAGIK_COMPARE_CACHE") { File.join(Dir.tmpdir, "magik-compare-cache") }
      site.config["magik"] = (site.config["magik"] || {}).merge("cache_dir" => cache)
      @api = Jekyll::Magik::Api.new(site, write_files: false)
      @pairs = {}
      @refs_by_url = nil
      @derive_seconds = 0.0
      @plans = {}
      @report = Hash.new(0)
      @examples = Hash.new { |h, k| h[k] = [] }
      @inline = {}
    end

    def count(key, example = nil)
      @report[key] += 1
      @examples[key] << example if example && @examples[key].size < MAX_EXAMPLES
    end

    def page_path(ctx)
      page = ctx.registers[:page]
      page && (page["relative_path"] || page["path"])
    end

    def plan(markup)
      @plans[markup] ||= Jekyll::Magik::Plan.new(markup)
    end

    def compare_tag(markup, ctx, theirs)
      plan = plan(markup)
      magick = plan.args.is_a?(Hash) && plan.args.key?(:magick)
      return count("tags: magick: (not compared; set MAGIK_COMPARE_DERIVATIVES=1)") if magick && !derivatives?

      example = { "page" => page_path(ctx), "tag" => "{% asset #{markup.strip} %}",
                  "jekyll-assets" => theirs }
      return compare_derivative(plan, ctx, theirs, example) if magick

      begin
        ctx.registers[:magik] = @api
        ours = Jekyll::Magik::Renderer.new(@api).render(plan, ctx)
      rescue Jekyll::Magik::Error => e
        # beekeeper moves its stylesheets to Jekyll's Sass before migrating (#6).
        return count("tags: stylesheets (out of scope)") if e.message.start_with?("stylesheets ")

        return count("tags: jekyll-magik raises", example.merge("error" => e.message))
      ensure
        ctx.registers.delete(:magik)
      end

      if plan.mode == :inline
        @inline[markup] = true
        return count("tags: @inline (jekyll-magik's own markup)")
      end

      if ours == theirs
        count("tags: identical (#{plan.mode})")
        ours.scan(%r{/assets/[^"'\s]+}).each { |url| check_url(url, example) }
      else
        count("tags: DIFFERENT", example.merge("jekyll-magik" => ours))
      end
    end

    # The derivative's markup now; its size after the write phase, when
    # jekyll-assets' file is in _site.
    def compare_derivative(plan, ctx, theirs, example)
      ctx.registers[:magik] = @api
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ours = Jekyll::Magik::Renderer.new(@api).render(plan, ctx)
      @derive_seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      ref = derivative_for(ours[%r{/assets/[^"'\s]+}])
      their_url = theirs[%r{/assets/[^"'\s]+}]
      @pairs[[their_url, ref.url]] ||= [ref, example.merge("jekyll-magik" => ours)]
      check_url(ref.url, example)
      return count("derivatives: @path") if plan.mode == :path

      stripped = theirs.sub(their_url, ref.url).sub(/ integrity="[^"]*"/, "").sub(' crossorigin="anonymous"',
                                                                                  "")
      if stripped == ours
        count("derivatives: <img> identical apart from src and integrity")
      else
        count("derivatives: <img> DIFFERENT", example.merge("jekyll-magik" => ours))
      end
    rescue Jekyll::Magik::Error => e
      count("tags: jekyll-magik raises", example.merge("error" => e.message))
    ensure
      ctx.registers.delete(:magik)
    end

    def derivative_for(url)
      @refs_by_url = @api.derivatives.to_h { |r| [r.url, r] } unless @refs_by_url&.key?(url)
      @refs_by_url.fetch(url)
    end

    def compare_derivative_sizes
      @pairs.each_value do |ref, example|
        their_file = File.join(@site.dest, example["jekyll-assets"][%r{/assets/[^"'\s]+}].to_s)
        theirs = FastImage.size(their_file)
        actual = FastImage.size(@api.store.object_path(ref.dkey, ref.ext))
        ours = [ref.width, ref.height]
        if theirs.nil?
          count("derivatives: jekyll-assets' file MISSING", example)
        elsif theirs == ours && actual == ours
          count("derivatives: same size as ImageMagick's")
        else
          count("derivatives: size DIFFERENT",
                example.merge("sizes" => { "imagemagick" => theirs, "predicted" => ours,
                                           "libvips" => actual }))
        end
      end
      report_derivative_stats
      @api.store.save(full_build: false, site_source: @site.source)
    end

    def report_derivative_stats
      stats = @api.stats
      {
        "unique (dkeys)" => stats[:derivatives], "references" => stats[:references],
        "cached" => stats[:cached], "processed" => stats[:processed],
        "seconds processing" => stats[:seconds].round(1),
        "seconds rendering tags, processing aside" => (@derive_seconds - stats[:seconds]).round(2)
      }.each { |key, value| @report["derivatives: #{key}"] = value }
    end

    def compare_digest_path(name, theirs)
      ours = @api.find!(name).url
      if ours == theirs
        count("api: seo-assets digest_path identical")
      else
        count("api: seo-assets digest_path DIFFERENT",
              { "name" => name, "jekyll-assets" => theirs, "jekyll-magik" => ours })
      end
    rescue Jekyll::Magik::Error => e
      count("api: seo-assets digest_path jekyll-magik raises", { "name" => name, "error" => e.message })
    end

    def compare_size(name, theirs)
      ours = @api.lookup(name.to_s)&.dimensions
      key = ours == theirs ? "api: image_size identical" : "api: image_size DIFFERENT"
      count(key, { "name" => name, "jekyll-assets" => theirs, "jekyll-magik" => ours })
    end

    def check_url(url, example)
      return count("urls: match the digest grammar") if DIGESTED.match(url)&.[](0) == url

      count("urls: OUTSIDE the digest grammar", example.merge("url" => url))
    end

    # Every original in the sprockets manifest: a file in the load paths
    # (the rest are resized copies and compiled stylesheets).
    def compare_manifest
      file = Dir[File.join(@site.dest, "assets", ".sprockets-manifest-*.json")].first
      return count("manifest: MISSING") unless file

      manifest = JSON.parse(File.read(file))
      resolver = Jekyll::Magik::Resolver.new(@api.config)
      manifest["assets"].each do |logical, digest_path|
        source = begin
          resolver.find(logical)
        rescue Jekyll::Magik::NotSupported => e
          count("manifest: not an original (#{e.message[/stylesheets|scripts/] || "unsupported"})")
          next
        end
        next count("manifest: not an original (resized copy)") unless source && source.logical_path == logical

        integrity = manifest.dig("files", digest_path, "integrity")
        example = { "logical_path" => logical, "jekyll-assets" => digest_path,
                    "jekyll-magik" => source.digest_path }
        if source.digest_path == digest_path && (integrity.nil? || integrity == source.integrity)
          count("manifest: originals identical")
        else
          count("manifest: originals DIFFERENT", example)
        end
        check_url(source.url, example)
      end
    end

    def finish
      compare_manifest
      compare_derivative_sizes if derivatives?
      out = { "counts" => @report.sort.to_h, "examples" => @examples }
      path = ENV.fetch("MAGIK_COMPARE_REPORT", nil)
      File.write(path, JSON.pretty_generate(out)) if path
      puts "\njekyll-magik vs jekyll-assets"
      @report.sort.each { |k, v| puts "  #{v.to_s.rjust(6)}  #{k}" }
      puts "  report: #{path}" if path
    end
  end

  module TagPatch
    def render(ctx)
      out = super
      MagikCompare.compare_tag(@args, ctx, out) if @args.is_a?(String)
      out
    end
  end

  module DigestPathPatch
    def digest_path(sprockets, name)
      out = super
      MagikCompare.compare_digest_path(name, out)
      out
    end
  end

  module ImageSizePatch
    def image_size(path)
      out = super
      MagikCompare.compare_size(path, out)
      out
    end
  end
end

Jekyll::Assets::Tag.prepend(MagikCompare::TagPatch)
if defined?(Jekyll::FrontmatterImage)
  Jekyll::FrontmatterImage.singleton_class.prepend(MagikCompare::DigestPathPatch)
end
Jekyll::ImageSizeFilter.prepend(MagikCompare::ImageSizePatch) if defined?(Jekyll::ImageSizeFilter)

Jekyll::Hooks.register :site, :after_reset do |site|
  MagikCompare.reset!(site)
end

Jekyll::Hooks.register :site, :post_write, priority: :low do |_site|
  MagikCompare.finish
end
