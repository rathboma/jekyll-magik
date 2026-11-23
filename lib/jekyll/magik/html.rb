# frozen_string_literal: true

module Jekyll
  module Magik
    # Writes <img> markup byte for byte as jekyll-assets did: it built the tag
    # with Nokogiri's HTML builder and serialized it with libxml2 (2.13).
    # test/html_test.rb checks this against golden output from Nokogiri.
    #
    # libxml2's rules for an attribute value:
    # - C0 control characters other than tab, newline and carriage return are
    #   dropped (NUL is refused)
    # - `&`, `<` and `>` become entities. Nothing is unescaped first, so
    #   `&amp;` becomes `&amp;amp;`
    # - the value is double-quoted, unless it contains `"` and no `'`: then
    #   it's single-quoted. With both, `"` becomes `&quot;`
    # - `src`, `href` and `action` are URIs: leading whitespace is dropped,
    #   and whitespace, DEL and non-ASCII bytes are percent-encoded
    # - HTML 4's boolean attributes (`ismap`, `disabled`, ...) are written as
    #   a bare name, whatever their value
    module Html
      URI_ATTRIBUTES = %w(src href action).freeze
      # libxml2's htmlIsBooleanAttr.
      BOOLEAN_ATTRIBUTES = %w(
        checked compact declare defer disabled ismap multiple nohref noresize noshade nowrap readonly selected
      ).freeze
      DROPPED = /[\x01-\x08\x0B\x0C\x0E-\x1F]/
      URI_ESCAPED = /[\x00-\x20\x7F]|[^\x00-\x7F]/
      ENTITIES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;" }.freeze
      NAME = /\A[A-Za-z_:][-A-Za-z0-9_:.]*\z/

      module_function

      # attributes: [[name, value], ...] in order.
      def img(attributes)
        return "<img>" if attributes.empty?

        "<img #{attributes.map { |name, value| attribute(name, value) }.join(" ")}>"
      end

      def attribute(name, value)
        name = name.to_s
        value = value.to_s
        raise Error, "an attribute value can't contain a NUL byte (#{name})" if value.include?("\0")

        return name if BOOLEAN_ATTRIBUTES.include?(name.downcase)

        value = value.gsub(DROPPED, "")
        value = uri_escape(value.sub(/\A[ \t\n\r]+/, "")) if URI_ATTRIBUTES.include?(name.downcase)
        value = value.gsub(/[&<>]/, ENTITIES)
        if !value.include?('"')
          %(#{name}="#{value}")
        elsif value.include?("'")
          %(#{name}="#{value.gsub('"', "&quot;")}")
        else
          "#{name}='#{value}'"
        end
      end

      def uri_escape(value)
        value.b.gsub(URI_ESCAPED) { |byte| format("%%%02X", byte.ord) }.force_encoding(value.encoding)
      end

      def valid_name?(name)
        NAME.match?(name.to_s)
      end
    end
  end
end
