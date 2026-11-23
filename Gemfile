# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# CI also runs the tests on the oldest Jekyll the gemspec allows:
# JEKYLL_VERSION="~> 4.3.0" bundle install
jekyll_version = ENV.fetch("JEKYLL_VERSION", "")
gem "jekyll", jekyll_version unless jekyll_version.empty?

group :development, :test do
  # Jekyll 4.3 requires these, which stopped being default gems in Ruby 3.4.
  gem "base64"
  gem "bigdecimal"
  gem "csv"
  gem "logger"

  # The reference implementation the tag's argument parser is checked against.
  gem "liquid-tag-parser", "2.0.2"
  gem "minitest", "~> 5.20"
  # Golden tests of jekyll-assets' <img> serialization, with the libxml2
  # (2.13) beekeeper-studio/web built with.
  gem "nokogiri", "~> 1.18.0"
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.60", require: false
end
