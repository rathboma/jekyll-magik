# frozen_string_literal: true

# Like beekeeper-studio/web's seo-assets.rb: an image referenced only from
# front matter, looked up through the Ruby API so it's written to _site.
Jekyll::Hooks.register :pages, :pre_render do |page, payload|
  name = page.data["image"]
  payload["page"]["og_image"] = page.site.magik.find!(name, page: payload["page"]).url if name.is_a?(String)
end
