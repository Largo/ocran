# frozen_string_literal: true

module Ocran
  module BuildHelper
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
  end
end
