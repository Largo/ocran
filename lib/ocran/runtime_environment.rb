# frozen_string_literal: true
require "pathname"

module Ocran
  class RuntimeEnvironment
    class << self
      alias save new
    end

    attr_reader :env, :load_path, :pwd

    def initialize
      @env = ENV.to_hash.freeze
      @load_path = $LOAD_PATH.dup.freeze
      @pwd = Dir.pwd.freeze
    end

    # Expands the given path using the working directory stored in this
    # instance as the base. This method resolves relative paths to
    # absolute paths, ensuring they are fully qualified based on the
    # working directory stored within this instance.
    def expand_path(path)
      File.expand_path(path, @pwd)
    end

    def find_load_path(path)
      path = Pathname(path) unless path.is_a?(Pathname)

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
