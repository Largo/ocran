# frozen_string_literal: true
require "pathname"

module Ocran
  load File.expand_path("refine_pathname.rb", __dir__) unless defined? RefinePathname
  using RefinePathname

  class RuntimeEnvironment
    class << self
      alias save new
    end

    # Matches the bundler/setup feature by which `bundle exec` sets a
    # process up, whatever prefix the bundler gem happens to be installed
    # under.
    BUNDLER_SETUP_FEATURE = %r{[\\/]bundler[\\/]setup\.rb\z}

    attr_reader :env, :load_path, :loaded_features, :pwd, :activated_gems

    def initialize
      @env = ENV.to_hash.freeze
      @load_path = $LOAD_PATH.dup.freeze
      @loaded_features = $LOADED_FEATURES.dup.freeze
      @pwd = Dir.pwd.freeze
      # The gems RubyGems had activated at this point. Under `bundle exec`
      # that is the entire bundle, activated before OCRAN's first line runs,
      # so a snapshot taken before the dependency run is what tells the build
      # environment's gems apart from the application's.
      @activated_gems = (defined?(Gem) ? Gem.loaded_specs.keys : []).freeze
    end

    # Whether Bundler had already set this process up when the snapshot was
    # taken. `bundle exec` arranges that through RUBYOPT (and, with newer
    # RubyGems, through the BUNDLER_SETUP variable), so bundler/setup is in
    # $LOADED_FEATURES before the command it runs gets to say anything.
    def bundler_setup_loaded?
      @loaded_features.any? { |feature| feature.to_s.match?(BUNDLER_SETUP_FEATURE) }
    end

    # Expands the given path using the working directory stored in this
    # instance as the base. This method resolves relative paths to
    # absolute paths, ensuring they are fully qualified based on the
    # working directory stored within this instance.
    def expand_path(path)
      File.expand_path(path, @pwd)
    end

    def find_load_path(path)
      path = Pathname.new(path) unless path.is_a?(Pathname)

      if path.absolute?
        # For an absolute path feature, find the load path that contains the feature
        # and determine the longest matching path (most specific path).
        @load_path.select { |load_path| path.subpath?(expand_path(load_path)) }
                  .max_by { |load_path| expand_path(load_path).length }
      else
        # For a relative path feature, find the load path where the expanded feature exists
        # and select the longest load path (most specific path).
        @load_path.select { |load_path| path.expand_path(load_path).exist? }
                  .max_by { |load_path| load_path.length }
      end
    end
  end
end
