# frozen_string_literal: true
require "pathname"

module Ocran
  module BuildHelper
    EMPTY_SOURCE = File.expand_path("empty_source", __dir__).freeze

    def copy_to_bin(source, target)
      cp(source, BINDIR / target)
    end

    def copy_to_gem_home(source, target)
      cp(source, GEMDIR / target)
    end

    def copy_to_lib(source, target)
      cp(source, LIBDIR / target)
    end

    def duplicate_to_exec_prefix(source)
      cp(source, Pathname(source).relative_path_from(HostConfigHelper.exec_prefix))
    end

    def duplicate_to_gem_home(source, gem_path)
      copy_to_gem_home(source, Pathname(source).relative_path_from(gem_path))
    end

    # Sets an environment variable with a joined path value.
    # This method processes an array of path strings or Pathname objects, accepts
    # absolute paths as is, and appends a placeholder to relative paths to convert
    # them into absolute paths. The converted paths are then joined into a single
    # string using the system's path separator.
    #
    # @param name [String] the name of the environment variable to set.
    # @param paths [Array<String, Pathname>] an array of path arguments which can
    #        be either absolute or relative.
    #
    # Example:
    #   set_env_path("RUBYLIB", "lib", "ext", "vendor/lib")
    #   # This sets RUBYLIB to a string such as "C:/ProjectRoot/lib;C:/ProjectRoot/ext;C:/ProjectRoot/vendor/lib"
    #   # assuming each path is correctly converted to an absolute path through a placeholder.
    #
    def set_env_path(name, *paths)
      value = paths.map { |path|
        if File.absolute_path?(path)
          path
        else
          File.join(TEMPDIR_ROOT, path)
        end
      }.join(File::PATH_SEPARATOR)

      export(name, value)
    end

    def touch(tgt)
      cp(EMPTY_SOURCE, tgt)
    end
  end
end
