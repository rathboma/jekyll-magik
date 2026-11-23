# frozen_string_literal: true

# jekyll-magik's classes, without registering anything with Jekyll or
# Liquid. `require "jekyll-magik"` (or the `plugins:` entry) does that; the
# parity scripts load only this, next to jekyll-assets.
#
# Never pipeline.rb or worker.rb: they load libvips, which only worker
# processes may (CLAUDE.md, rule 5).

require "jekyll"
require_relative "version"
require_relative "errors"
require_relative "mime"
require_relative "config"
require_relative "source"
require_relative "resolver"
require_relative "args"
require_relative "html"
require_relative "svg"
require_relative "transform"
require_relative "plan"
require_relative "store"
require_relative "processor"
require_relative "registry"
require_relative "tag"
require_relative "asset_file"
require_relative "manifest"
require_relative "api"
require_relative "filters"
require_relative "drop"
