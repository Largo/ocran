# frozen_string_literal: true
require "pathname"
require_relative "refine_pathname"
require_relative "command_output"

module Ocran
  module BuildHelper
    using RefinePathname

    include CommandOutput

    EMPTY_SOURCE = File.expand_path("empty_source", __dir__).freeze

    def mkdir(target)
      verbose "mkdir #{target}"
      super
    end

    def cp(source, target)
      verbose "cp #{source} #{target}"
      super
    end

    def exec(image, script, *argv)
      args = argv.map { |s| replace_placeholder(s) }.join(" ")
      verbose "exec #{image} #{script} #{args}"
      super
    end

    def export(name, value)
      verbose "export #{name}=#{replace_placeholder(value)}"
      super
    end

    def replace_placeholder(s)
      s.to_s.gsub(EXTRACT_ROOT.to_s, "<tempdir>")
    end
    private :replace_placeholder

    def copy_to_bin(source, target)
      cp(source, BINDIR / target)
    end

    def copy_to_gem(source, target)
      cp(source, GEMDIR / target)
    end

    def copy_to_lib(source, target)
      cp(source, LIBDIR / target)
    end

    def duplicate_to_exec_prefix(source)
      cp(source, Pathname(source).relative_path_from(HostConfigHelper.exec_prefix))
    end

    def duplicate_to_gem_home(source, gem_path)
      copy_to_gem(source, Pathname(source).relative_path_from(gem_path))
    end

    def resolve_source_path(source, root_prefix)
      source = Pathname(source)

      if source.subpath?(HostConfigHelper.exec_prefix)
        source.relative_path_from(HostConfigHelper.exec_prefix)
      elsif source.subpath?(root_prefix)
        SRCDIR / source.relative_path_from(root_prefix)
      else
        SRCDIR / source.basename
      end
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
          File.join(EXTRACT_ROOT, path)
        end
      }.join(File::PATH_SEPARATOR)

      export(name, value)
    end

    def touch(target)
      verbose "touch #{target}"
      cp(EMPTY_SOURCE, target)
    end
  end
end
