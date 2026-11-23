# frozen_string_literal: true

require "shellwords"

module Jekyll
  module Magik
    # The `{% asset %}` argument grammar of liquid-tag-parser 2.0.2, which
    # jekyll-assets uses. Ported line for line (ISC License, Copyright
    # 2017 - 2020 Jordon Bedwell; see LICENSE) so that every tag means what it
    # meant to jekyll-assets, quirks included; test/args_parity_test.rb runs
    # both over a corpus.
    #
    #   Args.parse(%(blog/a.png alt="A b" magick:resize=600x @magick:strip @path))
    #   # => { argv1: "blog/a.png", alt: "A b", magick: { resize: "600x", strip: true }, path: true }
    #
    # - shell words, with quoting
    # - `key=value`; `ns:key=value` nests; a repeated key becomes an array
    # - `@flag` is true and `!flag` false, namespaced too (`@magick:strip`)
    # - the first word, if it isn't one of those, is `argv1`
    # - values that look like integers or floats are converted
    # - `\=`, `\:` and `\@` escape the special characters
    module Args
      FLOAT = /\A\d+\.\d+\Z/
      BOOL = /\A(?<!\\)([!@])([\w:]+)\z/
      SPECIAL_ESCAPED = /\\([@!:=])/
      KEY = /\b(?<!\\):/
      INT = /^\d+$/
      SEP = /\b(?<!\\)(=)/
      ESCAPED_SEP = /\\(=)/
      TRUE_FLAG = "@"

      class ParseError < Error; end

      module_function

      def parse(raw)
        args = {}
        from_shellwords(raw).each_with_index do |word, idx|
          keys, _, val = word.rpartition(SEP)
          next if argv1(args, idx: idx, keys: keys, val: val)

          val = unescape(val)
          keys, val = flip_kv_bool(val) if val =~ BOOL && keys.empty?
          if keys.empty?
            keys = val
            val = nil
          end
          keys = keys.split(KEY).map(&:to_sym)

          set_val(hash: build_hash(args, keys), key: keys.last, val: convert(val))
        end
        args
      rescue ArgumentError, TypeError, NoMethodError => e
        raise ParseError, "can't parse the arguments: #{e.message}"
      end

      def argv1(args, idx:, keys:, val:)
        return false unless idx.zero? && keys.empty? && val !~ BOOL && val !~ SEP

        args[:argv1] = unescape(convert(val))
      end

      def flip_kv_bool(val)
        [val.gsub(BOOL, '\2'), val.start_with?(TRUE_FLAG)]
      end

      def build_hash(args, keys)
        out = args
        if keys.size > 1
          out = args[keys[0]] ||= {}
          keys[1...-1].each do |sk|
            out = out[sk] ||= {}
          end
        end
        out
      end

      def unescape(val)
        return unless val

        val.gsub(ESCAPED_SEP, "=").gsub(SPECIAL_ESCAPED, '\1')
      end

      def set_val(hash:, key:, val:)
        hash[key] << val if hash[key].is_a?(Array)
        hash[key] = [hash[key]].flatten << val if hash[key] && !hash[key].is_a?(Array)
        hash[key] = val unless hash[key]
      end

      def convert(val)
        return if val.nil?
        return val if [true, false].include?(val)
        return val.to_f if val =~ FLOAT
        return val.to_i if val =~ INT

        val
      end

      # liquid-tag-parser also substitutes [@!:=] and :// with themselves
      # first, which changes nothing.
      def from_shellwords(raw)
        Shellwords.shellsplit(raw.gsub(SEP, "\\="))
      end
    end
  end
end
