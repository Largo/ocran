# frozen_string_literal: true

module Ocran
  module LibraryDetector
    # Detect loaded shared libraries on POSIX systems (Linux, macOS)
    def self.loaded_dlls
      if RUBY_PLATFORM.include?("linux")
        detect_linux
      elsif RUBY_PLATFORM.include?("darwin")
        detect_macos
      else
        []
      end
    end

    def self.detect_linux
      File.readlines("/proc/self/maps").filter_map do |line|
        # Format: address perms offset dev ino pathname
        # Example: 56206f09c000-56206f0bc000 r--p 00000000 101:02 1234567   /path/to/lib.so.1
        fields = line.split
        path = fields[5]

        # Only include absolute paths to shared libraries
        next unless path&.start_with?("/")
        next unless path.end_with?(".so") || path.match?(/\.so\.\d/)

        path
      end.uniq
    end

    def self.detect_macos
      # On macOS, we can use `vmmap` to list the memory regions, but it's slow.
      # A better way might be using ObjectSpace for loaded features, but that's for Ruby files.
      # For shared libraries (.dylib), we can use `otool -L` on the ruby binary,
      # but that only gives linked libraries, not dynamically loaded ones.
      # For now, let's use `vmmap` or similar if available, or just rely on $LOADED_FEATURES for Ruby-based extensions.

      # Using `vmmap` is one way to get mapped files:
      libs = []
      begin
        IO.popen(["vmmap", Process.pid.to_s], err: [:child, :out]) do |io|
          io.each_line do |line|
            # Look for lines with paths ending in .dylib
            if line =~ %r{ (/.*\.dylib)$}
              libs << $1
            end
          end
        end
      rescue Errno::ENOENT
        # vmmap not available
      end
      libs.uniq
    end
  end
end
