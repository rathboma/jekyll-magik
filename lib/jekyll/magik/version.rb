# frozen_string_literal: true

module Jekyll
  module Magik
    VERSION = "0.1.0"

    # Part of every derivative's content key (dkey), so changing it renames
    # every derivative. Bump it when the output of an existing transform
    # should change: a resampling kernel, an encoder setting, a built-in
    # default. The libvips version is deliberately not part of the key.
    PIPELINE_VERSION = 2
  end
end
