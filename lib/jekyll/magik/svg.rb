# frozen_string_literal: true

module Jekyll
  module Magik
    # `{% asset x.svg @inline %}`: the file's own markup, with the tag's
    # attributes set on its root <svg> element.
    #
    # The markup is kept byte for byte (no XML round trip), so attribute case
    # (`viewBox`), quoting and whitespace survive, except that the XML
    # declaration and any doctype are dropped, since neither belongs inside an
    # HTML page, along with surrounding whitespace. An attribute the root
    # already has gets the tag's value in place; others are added after its
    # last attribute.
    module Svg
      PROLOG = /\G<\?.*?\?>/m
      COMMENT = /\G<!--.*?-->/m
      DOCTYPE = /\G<!DOCTYPE(?:[^>\[]|\[[^\]]*\])*>/mi
      SPACE = /\G\s+/
      ROOT = /\G<svg(?=[\s>\/])/
      ATTRIBUTE = /\G(\s+)([^\s=\/>]+)\s*=\s*(?:"[^"]*"|'[^']*')/
      TAG_END = /\G\s*\/?>/

      module_function

      # attributes: [[name, value], ...]. filename: for error messages.
      def inline(markup, attributes, filename:)
        svg = markup.dup.force_encoding(Encoding::UTF_8)
        raise NotSupported, "#{filename} isn't UTF-8, so it can't be inlined" unless svg.valid_encoding?

        svg = svg.delete_prefix("﻿")
        prefix, root_at = skip_prolog(svg, filename)
        attrs, attrs_end = parse_root(svg, root_at, filename)
        out = +""
        out << prefix
        out << set_attributes(svg, root_at, attrs, attrs_end, attributes)
        out << svg[attrs_end..]
        out.strip
      end

      # Everything before the root element, minus XML declarations and
      # doctypes, and where the root starts.
      def skip_prolog(svg, filename)
        pos = 0
        kept = +""
        loop do
          if (m = svg.match(SPACE, pos)) || (m = svg.match(PROLOG, pos)) || (m = svg.match(DOCTYPE, pos))
            kept << m[0] if m[0].strip.empty?
          elsif (m = svg.match(COMMENT, pos))
            kept << m[0]
          elsif svg.match?(ROOT, pos)
            return [kept.strip.empty? ? "" : "#{kept.strip}\n", pos]
          else
            raise NotSupported, "#{filename} doesn't start with an <svg> element, so it can't be inlined"
          end
          pos = m.end(0)
        end
      end

      # The root's attributes as [name, start, end], and where they end.
      def parse_root(svg, root_at, filename)
        pos = root_at + 4
        attrs = []
        while (m = svg.match(ATTRIBUTE, pos))
          attrs << [m[2], m.begin(2), m.end(0)]
          pos = m.end(0)
        end
        raise NotSupported, "can't parse the <svg> start tag of #{filename}" unless svg.match?(TAG_END, pos)

        [attrs, pos]
      end

      def set_attributes(svg, root_at, attrs, attrs_end, attributes)
        tag = svg[root_at...attrs_end]
        additions = +""
        replacements = []
        attributes.each do |name, value|
          name = name.to_s
          written = %(#{name}="#{escape(value.to_s)}")
          existing = attrs.find { |attr_name, _, _| attr_name == name }
          if existing
            replacements << [existing[1] - root_at, existing[2] - root_at, written]
          else
            additions << " #{written}"
          end
        end
        replacements.sort_by { |start, _, _| -start }.each do |start, stop, written|
          tag[start...stop] = written
        end
        tag + additions
      end

      def escape(value)
        value.gsub(/[&<>"\t\n\r]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;",
                                   "\t" => "&#9;", "\n" => "&#10;", "\r" => "&#13;")
      end
    end
  end
end
