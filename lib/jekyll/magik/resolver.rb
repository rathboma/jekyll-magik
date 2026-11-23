# frozen_string_literal: true

module Jekyll
  module Magik
    # Finds the file an asset name refers to, with sprockets 4's rules, and
    # gives it the logical path sprockets would.
    #
    # - The load paths are searched in order (the configured `sources`, then
    #   jekyll-assets' defaults); the first load path with a match wins.
    # - `blog/default.jpg` is found in any load path, so in `_assets/img` too.
    # - A name's extension is matched by type, so `foo.jpg` also finds
    #   `foo.jpeg`.
    # - A name without an extension (`screenshots/main-dark`) matches any file
    #   with that name and a registered extension, and the first in sorted
    #   order wins (`edit-schema.jpg` before `edit-schema.png`). A directory's
    #   `index` file comes after those.
    # - The logical path is the file's path relative to the *first* load path
    #   that contains it: `blog/default.jpg` found in `_assets/img` is
    #   `img/blog/default.jpg` when `_assets` is a load path too.
    #
    # A Resolver lives for one build. Each directory is listed at most once,
    # on first use, and every name's result is memoized, so a tag costs a
    # hash lookup after the first time its name is seen.
    class Resolver
      Candidate = Struct.new(:filename, :type)

      attr_reader :config

      def initialize(config)
        @config = config
        @load_paths = config.load_paths.select { |path| File.directory?(path) }
        @listings = {}
        @files = {}
        @results = {}
        @sources = {}
      end

      # The Source for a name, or nil when there's no such asset. Raises
      # NotSupported for names and files jekyll-magik doesn't serve.
      def find(name)
        name = name.to_s
        return @results[name] if @results.key?(name)

        @results[name] = resolve(name)
      end

      private

      def resolve(name)
        return nil unless valid_name?(name)

        ext, type = Mime.extname(name)
        logical_name = ext ? name.delete_suffix(ext) : name
        if (pipeline = Mime::PIPELINE_EXTS.find { |e| logical_name.end_with?(e) })
          raise NotSupported, "sprockets pipelines (#{pipeline}) aren't supported"
        end
        raise NotSupported, Mime.unsupported_reason(type, ext) if type && !Mime.passthrough?(type)

        accepts = type ? [type, *Mime::ACCEPTS_ALSO[type]] : nil
        candidate = nil
        @load_paths.each do |load_path|
          candidate = pick(candidates(load_path, logical_name), accepts)
          break if candidate
        end
        candidate && source_for(candidate)
      end

      # False for names that aren't relative to the load paths: sprockets
      # resolves absolute names and `./` or `../` differently, and empty or
      # `.` segments would make broken URLs. External URLs raise.
      def valid_name?(name)
        raise NotSupported, "external URLs aren't supported" if name.match?(%r{\A(?:[a-z][a-z0-9+.-]*:)?//}i)

        !name.empty? && !name.include?("\0") &&
          name.split("/", -1).none? { |seg| seg.empty? || seg == "." || seg == ".." }
      end

      # Sprockets' resolve_main_under_path and resolve_index_under_path.
      def candidates(load_path, logical_name)
        dirname = File.dirname(logical_name)
        dir = dirname == "." ? load_path : File.join(load_path, dirname)
        found = matches(dir, File.basename(logical_name))
        index_dir = File.join(load_path, logical_name)
        found += matches(index_dir, "index") if listing(index_dir)
        found
      end

      def matches(dir, basename)
        entries = listing(dir)&.fetch(basename, nil)
        return [] unless entries

        entries.filter_map do |entry, type|
          filename = File.join(dir, entry)
          Candidate.new(filename, type) if file?(filename)
        end
      end

      # Sprockets' HTTPUtils.find_best_q_match: the first accepted type (they
      # are in falling order of quality) with a candidate, and the first
      # candidate of that type. With no extension, anything goes.
      def pick(candidates, accepts)
        return candidates.first if accepts.nil?

        accepts.each do |accept|
          found = candidates.find { |c| c.type == accept }
          return found if found
        end
        nil
      end

      # A directory's entries, sorted and grouped by their name without a
      # registered extension, the way sprockets' PathUtils#entries and
      # find_matching_path_for_extensions see them. nil if it isn't a
      # directory.
      def listing(dir)
        return @listings[dir] if @listings.key?(dir)

        @listings[dir] = begin
          entries = Dir.children(dir).reject { |e| hidden?(e) }.sort
          entries.each_with_object({}) do |entry, groups|
            ext, type = Mime.extname(entry)
            (groups[ext ? entry.delete_suffix(ext) : entry] ||= []) << [entry, type]
          end
        rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
          nil
        end
      end

      def hidden?(entry)
        entry.start_with?(".") || (entry.start_with?("#") && entry.end_with?("#")) || entry.end_with?("~")
      end

      def file?(filename)
        return @files[filename] if @files.key?(filename)

        @files[filename] = File.file?(filename)
      end

      def source_for(candidate)
        @sources[candidate.filename] ||= begin
          type = candidate.type
          ext = Mime.extname(candidate.filename)&.first
          raise NotSupported, Mime.unsupported_reason(type, ext || File.extname(candidate.filename)) \
            unless type && Mime.passthrough?(type)

          Source.new(
            filename: candidate.filename,
            logical_path: logical_path(candidate.filename),
            content_type: type,
            config: config
          )
        end
      end

      # Sprockets' PathUtils.paths_split over every configured load path.
      def logical_path(filename)
        config.load_paths.each do |path|
          prefix = File.join(path, "")
          return filename.delete_prefix(prefix) if filename.start_with?(prefix)
        end
        raise Error, "#{filename} is outside the asset load paths"
      end
    end
  end
end
