# frozen_string_literal: true
require "pathname"

module Ocran
  # The Pathname class in Ruby is modified to handle mixed path separators and
  # to be case-insensitive.
  #
  # Caveat: refinements apply only to calls written in a file that is
  # `using RefinePathname`. Hash, Set, Array#uniq, Array#include? and Array#-
  # call hash/eql?/== from C, which never sees a refinement, so collections
  # of Pathnames keep comparing them case- and separator-sensitively. Where
  # a collection has to treat two spellings of one file as the same, key it
  # on Pathname#path_key instead (e.g. `paths.uniq { |p| p.path_key }`).
  module RefinePathname
    # The spelling-independent form of +path+ on this platform: separators
    # unified and, on case-insensitive file systems (Windows), downcased. On
    # POSIX it is the path itself.
    def self.path_key(path)
      s = path.to_s
      s = s.tr(File::ALT_SEPARATOR, File::SEPARATOR) if File::ALT_SEPARATOR
      s = s.downcase if File::FNM_SYSCASE.nonzero?
      s
    end

    refine Pathname do
      def normalize_file_separator(s)
        if File::ALT_SEPARATOR
          s.tr(File::ALT_SEPARATOR, File::SEPARATOR)
        else
          s
        end
      end
      private :normalize_file_separator

      def to_posix
        normalize_file_separator(to_s)
      end

      # See RefinePathname.path_key. Two Pathnames denote the same file on
      # this platform when their keys are equal.
      def path_key
        RefinePathname.path_key(self)
      end

      # Checks if two Pathname objects are equal, considering the file system's
      # case sensitivity and path separators. Returns false if the other object is not
      # an Pathname.
      # NOTE: only calls written in refined code see this; Array#uniq and
      # the like do not (see the caveat on RefinePathname).
      def eql?(other)
        return false unless other.is_a?(Pathname)

        path_key == other.path_key
      end

      alias == eql?
      alias === eql?

      # A hash value consistent with eql?, based on the normalized path. As
      # with eql?, Hash and Set do not call this refinement.
      #
      # @return [Integer] A hash integer based on the normalized path.
      def hash
        path_key.hash
      end

      # Checks if the current path is a sub path of the specified base_directory.
      # Both paths must be either absolute paths or relative paths; otherwise, this
      # method returns false.
      def subpath?(base_directory)
        s = relative_path_from(base_directory).each_filename.first
        s != '.' && s != ".."
      rescue ArgumentError
        false
      end

      # Appends the given suffix to the filename, preserving the file extension.
      # If the filename has an extension, the suffix is inserted before the extension.
      # If the filename does not have an extension, the suffix is appended to the end.
      # This method handles both directory and file paths correctly.
      #
      # Examples:
      #   pathname = Pathname("path.to/foo.tar.gz")
      #   pathname.append_to_filename("_bar") # => #<Pathname:path.to/foo_bar.tar.gz>
      #
      #   pathname = Pathname("path.to/foo")
      #   pathname.append_to_filename("_bar") # => #<Pathname:path.to/foo_bar>
      #
      def append_to_filename(suffix)
        dirname + basename.sub(/(\.?[^.]+)?(\..*)?\z/, "\\1#{suffix}\\2")
      end

      # Checks if the file's extension matches the expected extension.
      # The comparison is case-insensitive.
      # Example usage: ocran_pathname.extname?(".exe")
      def extname?(expected_ext)
        extname.casecmp(expected_ext) == 0
      end
    end
  end
end
