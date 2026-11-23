# frozen_string_literal: true

module Jekyll
  module Magik
    # The file extensions sprockets 4 (plus jekyll-assets) registers, and what
    # jekyll-magik does with each type.
    #
    # The whole table matters, not just the image types: sprockets only treats
    # a registered extension as an extension. When `{% asset foo %}` names no
    # extension, `foo.png` and `foo.scss` are candidates for it and `foo.psd`
    # isn't, so the table decides which file an extensionless name finds.
    module Mime
      # Dumped from Sprockets' config[:mime_exts] with jekyll-assets loaded.
      EXTS = {
        ".aac" => "audio/aac", ".aiff" => "audio/aiff", ".au" => "audio/basic",
        ".avi" => "video/avi", ".bmp" => "image/bmp",
        ".coffee" => "text/coffeescript", ".coffee.erb" => "application/coffeescript+ruby",
        ".coffee.liquid" => "text/liquid+coffeescript",
        ".css" => "text/css", ".css.erb" => "application/css+ruby",
        ".css.liquid" => "text/liquid+css", ".css.map" => "application/css-sourcemap+json",
        ".css.sass" => "text/sass", ".css.sass.erb" => "application/sass+ruby",
        ".css.scss" => "text/scss", ".css.scss.erb" => "application/scss+ruby",
        ".eco" => "text/eco", ".eco.erb" => "application/eco+ruby",
        ".ejs" => "text/ejs", ".ejs.erb" => "application/ejs+ruby",
        ".eot" => "application/vnd.ms-fontobject", ".erb" => "application/html+ruby",
        ".es6" => "application/ecmascript-6", ".es6.erb" => "application/ecmascript-6+ruby",
        ".es6.liquid" => "application/liquid+ecmascript-6",
        ".flac" => "audio/flac", ".gif" => "image/gif",
        ".htm" => "text/html", ".htm.erb" => "application/html+ruby",
        ".html" => "text/html", ".html.erb" => "application/html+ruby",
        ".ico" => "image/x-icon", ".jpeg" => "image/jpeg", ".jpg" => "image/jpeg",
        ".js" => "application/javascript", ".js.coffee" => "text/coffeescript",
        ".js.coffee.erb" => "application/coffeescript+ruby",
        ".js.erb" => "application/javascript+ruby", ".js.liquid" => "application/liquid+javascript",
        ".js.map" => "application/js-sourcemap+json",
        ".json" => "application/json", ".json.erb" => "application/json+ruby",
        ".jst.eco" => "text/eco", ".jst.eco.erb" => "application/eco+ruby",
        ".jst.ejs" => "text/ejs", ".jst.ejs.erb" => "application/ejs+ruby",
        ".liquid.coffee" => "text/liquid+coffeescript", ".liquid.css" => "text/liquid+css",
        ".liquid.es6" => "application/liquid+ecmascript-6",
        ".liquid.js" => "application/liquid+javascript", ".liquid.sass" => "text/liquid+sass",
        ".liquid.scss" => "text/liquid+scss", ".liquid.svg" => "image/liquid+svg+xml",
        ".m2a" => "audio/mpeg", ".m3a" => "audio/mpeg", ".m4a" => "audio/mp4",
        ".m4v" => "video/mp4", ".mid" => "audio/midi", ".midi" => "audio/midi",
        ".mp2" => "audio/mpeg", ".mp3" => "audio/mpeg", ".mp4" => "video/mp4",
        ".oga" => "audio/ogg", ".ogg" => "audio/ogg", ".ogx" => "application/ogg",
        ".otf" => "application/x-font-opentype", ".png" => "image/png",
        ".rb" => "application/ruby", ".rhtml" => "application/html+ruby",
        ".rxml" => "application/xml+ruby",
        ".sass" => "text/sass", ".sass.erb" => "application/sass+ruby",
        ".sass.liquid" => "text/liquid+sass",
        ".scss" => "text/scss", ".scss.erb" => "application/scss+ruby",
        ".scss.liquid" => "text/liquid+scss",
        ".snd" => "audio/basic", ".svg" => "image/svg+xml", ".svg.liquid" => "image/liquid+svg+xml",
        ".text" => "text/plain", ".text.erb" => "application/plain+ruby",
        ".tif" => "image/tiff", ".tiff" => "image/tiff", ".ttf" => "application/x-font-ttf",
        ".txt" => "text/plain", ".txt.erb" => "application/plain+ruby",
        ".wav" => "audio/wave", ".wave" => "audio/wave", ".webm" => "video/webm",
        ".webmanifest" => "application/manifest+json",
        ".webmanifest.erb" => "application/manifest+json+ruby",
        ".webp" => "image/webp", ".woff" => "application/font-woff",
        ".woff2" => "application/font-woff2", ".xml" => "application/xml",
        ".xml.erb" => "application/xml+ruby",
        ".yaml" => "text/yaml", ".yaml.erb" => "application/yaml+ruby",
        ".yml" => "text/yaml", ".yml.erb" => "application/yaml+ruby"
      }.freeze

      # Sprockets' pipeline suffixes (`foo.css.debug`). Not supported.
      PIPELINE_EXTS = %w(.source .self .default .debug).freeze

      # Types a request for another type also accepts, because sprockets can
      # transform them into it (`foo.svg` finds `foo.liquid.svg`). Only the
      # entries for types jekyll-magik serves; the rest are unsupported anyway.
      ACCEPTS_ALSO = { "image/svg+xml" => ["image/liquid+svg+xml"].freeze }.freeze

      # What the default tag mode can render as an <img>.
      IMG_TYPES = %w(image/png image/jpeg image/webp image/gif image/svg+xml).freeze

      SVG = "image/svg+xml"

      # Binary types sprockets serves byte for byte: no processors, digested
      # from the file's own bytes. These are the only ones jekyll-magik
      # serves, since their URLs and contents are provably jekyll-assets'.
      PASSTHROUGH = (EXTS.values.uniq.grep(%r{\A(?:image/(?!liquid)|audio/|video/)}) + %w(
        application/font-woff application/font-woff2 application/x-font-ttf
        application/x-font-opentype application/vnd.ms-fontobject
      )).freeze

      module_function

      # Sprockets' PathUtils.match_path_extname: the longest registered
      # extension of the basename, tried from its first dot. Returns
      # [extname, type] or nil.
      def extname(path)
        basename = File.basename(path)
        i = basename.index(".")
        while i && i < basename.length - 1
          ext = basename[i..]
          type = EXTS[ext]
          return [ext, type] if type

          i = basename.index(".", i + 1)
        end
        nil
      end

      def passthrough?(type)
        PASSTHROUGH.include?(type)
      end

      # Why a type isn't served, for "not supported" errors.
      def unsupported_reason(type, ext)
        case type
        when %r{css|sass|scss}
          "stylesheets (#{ext}) aren't supported: use Jekyll's own Sass converter"
        when %r{javascript|ecmascript|coffee|eco|ejs}
          "scripts (#{ext}) aren't supported: use a JavaScript bundler"
        when %r{liquid}
          "Liquid assets (#{ext}) aren't supported"
        when nil
          "files with an unregistered extension aren't supported"
        else
          "#{ext} assets (#{type}) aren't supported"
        end
      end
    end
  end
end
