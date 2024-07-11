# frozen_string_literal: true
require "pathname"

module Ocran
  # The Pathname class in Ruby is modified to handle mixed path separators and
  # to be case-insensitive.
  module RefinePathname
    def normalize_file_separator(s)
      if File::ALT_SEPARATOR
        s.tr(File::ALT_SEPARATOR, File::SEPARATOR)
      else
        s
      end
    end
    private :normalize_file_separator

    # Compares two paths for equality based on the case sensitivity of the
    # Ruby execution environment's file system.
    # If the file system is case-insensitive, it performs a case-insensitive
    # comparison. Otherwise, it performs a case-sensitive comparison.
    def pathequal(a, b)
      if File::FNM_SYSCASE.nonzero?
        a.casecmp(b) == 0
      else
        a == b
      end
    end
    private :pathequal

    def to_posix
      normalize_file_separator(to_s)
    end

    # Checks if two Pathname objects are equal, considering the file system's
    # case sensitivity and path separators. Returns false if the other object is not
    # an Pathname.
    # This method enables the use of the `uniq` method on arrays of Pathname objects.
    def eql?(other)
      return false unless other.is_a?(Pathname)

      a = normalize_file_separator(to_s)
      b = normalize_file_separator(other.to_s)
      pathequal(a, b)
    end

    alias == eql?
    alias === eql?

    # Calculates a normalized hash value for a pathname to ensure consistent
    # hashing across different environments, particularly in Windows.
    # This method first normalizes the path by:
    # 1. Converting the file separator from the platform-specific separator
    #    to the common POSIX separator ('/') if necessary.
    # 2. Converting the path to lowercase if the filesystem is case-insensitive.
    # The normalized path string is then hashed, providing a stable hash value
    # that is consistent with the behavior of eql? method, thus maintaining
    # the integrity of hash-based data structures like Hash or Set.
    #
    # @return [Integer] A hash integer based on the normalized path.
    def hash
      path = if File::FNM_SYSCASE.nonzero?
               to_s.downcase
             else
               to_s
             end
      normalize_file_separator(path).hash
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
