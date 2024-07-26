# frozen_string_literal: true
require "rubygems"
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
      # find_gem_path method searches for the path of the gem containing the
      # specified path. The 'path' argument is a file or directory path.
      # It checks each gem's installation path in Gem.path to see if the
      # specified path is a subpath. Returns the gem's path if found, or
      # nil if not found.
      def find_gem_path(path)
        return unless defined?(Gem)

        Gem.path.find { |gem_path| Pathname(path).subpath?(gem_path) }
      end

      # find_spec_file method searches for the path of the gemspec file of
      # the gem containing the specified path. The 'path' argument is a file
      # or directory path. It searches within the "gems" directory in each
      # directory listed in Gem.path to check if the specified path is a
      # subpath. If the gemspec file exists, it returns its path; otherwise,
      # it returns nil.
      def find_spec_file(path)
        return unless defined?(Gem)

        feature = Pathname(path)
        Gem.path.each do |gem_path|
          gems_dir = File.join(gem_path, "gems")
          next unless feature.subpath?(gems_dir)

          full_name = feature.relative_path_from(gems_dir).each_filename.first
          spec_path = File.join(gem_path, "specifications", "#{full_name}.gemspec")
          return spec_path if File.exist?(spec_path)
        end
        nil
      end

      # find_spec method searches and returns a Gem::Specification object
      # based on the specified path. Internally, it uses find_spec_file to
      # obtain the path to the gemspec file, and if that file exists, it
      # calls Gem::Specification.load to load the gem's specifications.
      # Returns the loaded Gem::Specification object, or nil if the gemspec
      # file does not exist.
      def find_spec(path)
        return unless defined?(Gem)

        spec_file = find_spec_file(path)
        spec_file && Gem::Specification.load(spec_file)
      end

      def scanning_gemfile(gemfile_path)
        # Ensure the necessary libraries are loaded to scan the Gemfile.
        # This is particularly useful in custom-built Ruby environments or
        # where certain libraries might be excluded.
        %w[rubygems bundler].each do |lib|
          require lib
        rescue LoadError
          raise "Couldn't scan Gemfile, unable to load #{lib}"
        end

        ENV["BUNDLE_GEMFILE"] = gemfile_path.to_s
        # Bundler.load.specs includes the spec for Bundler itself
        Bundler.load.specs.to_a
      end

      # Fall back to gem detection
      def detect_gems_from(features, verbose: false)
        features.inject([]) do |gems, feature|
          if gems.any? { |spec| feature.subpath?(spec.gem_dir) }
            # Skip if found in known Gem dir
          elsif (spec = GemSpecQueryable.find_spec(feature))
            gems << spec
          else
            puts "Failed to load gemspec for #{feature}" if verbose
          end

          gems
        end
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

    def find_gem_files(file_sets, features_from_gems)
      actual_files = file_sets.flat_map do |set|
        case set
        when :spec
          files.map { |file| Pathname(file) }
        when :loaded
          features_from_gems.select { |feature| feature.subpath?(gem_dir) }
        when :files
          resource_files
        when :extras
          extra_files
        when :scripts
          script_files
        else
          raise "Invalid file set: #{set}. Please specify a valid file set (:spec, :loaded, :files, :extras, :scripts)."
        end
      end
      actual_files.uniq
      actual_files
    end
  end
end
