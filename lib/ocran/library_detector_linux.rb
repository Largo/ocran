# frozen_string_literal: true

module Ocran
  module LibraryDetector
    # Detect loaded shared libraries on Linux by parsing /proc/self/maps
    def self.loaded_dlls
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
  end
end
