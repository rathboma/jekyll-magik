# frozen_string_literal: true

require_relative "lib/jekyll/magik/version"

Gem::Specification.new do |spec|
  spec.name = "jekyll-magik"
  spec.version = Jekyll::Magik::VERSION
  spec.authors = ["The jekyll-magik authors"]
  spec.summary = "Fast image processing for Jekyll's {% asset %} tag with libvips, " \
                 "compatible with jekyll-assets"
  spec.description = "A drop-in replacement for the image side of jekyll-assets: the same " \
                     "{% asset %} tag and URLs, without sprockets or ImageMagick."
  spec.homepage = "https://github.com/rathboma/jekyll-magik"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "fastimage", ">= 2.2", "< 3"
  spec.add_dependency "jekyll", ">= 4.3", "< 5"
  # Loaded only by the worker processes that resize images, never by Jekyll's
  # own process (see CLAUDE.md, rule 5).
  spec.add_dependency "ruby-vips", "~> 2.2"
end
