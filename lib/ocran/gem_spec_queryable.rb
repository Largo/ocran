# frozen_string_literal: true
require "pathname"

module Ocran
  module GemSpecQueryable
    GEM_SCRIPT_RE = /\.rbw?$/
    GEM_EXTRA_RE = %r{(
      # Auxiliary files in the root of the gem
      ^(\.\/)?(History|Install|Manifest|README|CHANGES|Licen[sc]e|Contributors|ChangeLog|BSD|GPL).*$ |
      # Installation files in the root of the gem
      ^(\.\/)?(Rakefile|setup.rb|extconf.rb)$ |
      # Documentation/test directories in the root of the gem
      ^(\.\/)?(doc|ext|examples|test|tests|benchmarks|spec)\/ |
      # Directories anywhere
      (^|\/)(\.autotest|\.svn|\.cvs|\.git)(\/|$) |
      # Unlikely extensions
      \.(rdoc|c|cpp|c\+\+|cxx|h|hxx|hpp|obj|o|a)$
    )}xi
    GEM_NON_FILE_RE = /(#{GEM_EXTRA_RE}|#{GEM_SCRIPT_RE})/

    class << self
      def find_gem_path(feature)
        return unless defined?(Gem)

        Gem.path.find { |path| Pathname(feature).subpath?(path) }
      end

      def find_gemspec_path(feature)
        return unless defined?(Gem)

        Gem.path.each do |gem_path|
          gems_dir = File.join(gem_path, "gems")
          next unless feature.subpath?(gems_dir)

          full_name = feature.relative_path_from(gems_dir).each_filename.first
          spec_path = File.join(gem_path, "specifications", "#{full_name}.gemspec")
          return spec_path if File.exist?(spec_path)
        end
        nil
      end
    end

    def gem_root = Pathname(gem_dir)

    # Find the selected files
    def gem_root_files = gem_root.find.select(&:file?)

    def script_files
      gem_root_files.select { |path| path.extname =~ GEM_SCRIPT_RE }
    end

    def extra_files
      gem_root_files.select { |path| path.relative_path_from(gem_root).to_posix =~ GEM_EXTRA_RE }
    end

    def resource_files
      files = gem_root_files.select { |path| path.relative_path_from(gem_root).to_posix !~ GEM_NON_FILE_RE }
      files << Pathname(gem_build_complete_path) if File.exist?(gem_build_complete_path)
      files
    end
  end
end
