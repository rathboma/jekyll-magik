# frozen_string_literal: true

require "json"

module Jekyll
  module Magik
    # magik-manifest.json in the asset destination (`magik.manifest: true`):
    # every asset the build wrote, by URL. Originals have their logical path,
    # derivatives their logical source path, canonical transform and size.
    # bench/parity (#5) compares builds with it, and the beekeeper-studio/web
    # migration (#6) builds redirects from it.
    class ManifestFile < Jekyll::StaticFile
      include OutputFile

      NAME = "magik-manifest.json"

      def initialize(site, api)
        @api = api
        @dest_rel = api.config.dest_path_for(NAME).delete_prefix("/")
        super(site, site.source, File.dirname(@dest_rel), NAME)
      end

      # It has no source file; Jekyll's regenerator then always writes it.
      def path
        File.join(@site.source, ".magik-manifest-#{object_id}")
      end

      def modified_time
        @site.time
      end

      # Rewritten only when its contents change.
      def write(dest)
        dest_path = destination(dest)
        json = "#{JSON.pretty_generate(@api.manifest)}\n"
        return false if File.file?(dest_path) && File.binread(dest_path) == json

        replace(dest_path) { |tmp| File.binwrite(tmp, json) }
        true
      end
    end
  end
end
