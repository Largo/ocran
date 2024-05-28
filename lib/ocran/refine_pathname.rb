# frozen_string_literal: true
require "pathname"

module Ocran
  # Path handling refinements. These refinements extend Ruby's Pathname class
  # to handle case sensitivity and mixed path separators correctly based on the
  # file system of the execution environment.
  module RefinePathname
    refine Pathname do
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
        if File::ALT_SEPARATOR
          to_s.tr(File::ALT_SEPARATOR, File::SEPARATOR)
        else
          to_s
        end
      end

      # Checks if two Pathname objects are equal, considering the file system's
      # case sensitivity and path separators. Returns false if the other object is not
      # an Pathname.
      # This method enables the use of the `uniq` method on arrays of Pathname objects.
      def eql?(other)
        return false unless other.is_a?(Pathname)

        a = to_posix
        b = other.to_posix
        pathequal(a, b)
      end

      alias == eql?
      alias === eql?

      # Compute the relative path from the 'src' path (directory) to 'tgt'
      # (directory or file). Return the absolute path to 'tgt' if it can't
      # be reached from 'src'.
      def relative_path_from(other)
        a = to_s.split(Pathname::SEPARATOR_PAT)
        b = other.to_s.split(Pathname::SEPARATOR_PAT)
        while a.first && b.first && pathequal(a.first, b.first)
          a.shift
          b.shift
        end
        return other if b.first && Pathname.new(b.first).absolute?
        b.size.times { a.unshift ".." }
        Pathname.new(File.join(*a))
      end

      # Checks if the current path is a subpath of the specified base_directory.
      # Both paths must be either absolute paths or relative paths; otherwise, this
      # method returns false.
      def subpath?(base_directory)
        base_directory = Pathname.new(base_directory) unless base_directory.is_a?(Pathname)
        src_normalized = to_posix
        tgt_normalized = base_directory.to_posix
        src_normalized =~ /^#{Regexp.escape tgt_normalized}#{Pathname::SEPARATOR_PAT}/i
      #   relative_path = relative_path_from(base_directory)
      #   s = relative_path.to_s
      #   s != '.' && s !~ /\A\.\.#{Pathname::SEPARATOR_PAT}/
      # rescue ArgumentError
      #   false
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
        sub(/(.*?#{Pathname::SEPARATOR_PAT})?(\.?[^.]+)?(\..*)?\z/, "\\1\\2#{suffix}\\3")
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
