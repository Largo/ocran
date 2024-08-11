# frozen_string_literal: true
require "fiddle/import"
require "fiddle/types"

module Ocran
  # Changes the Icon in a PE executable.
  module EdIcon
    extend Fiddle::Importer
    dlload "kernel32.dll"

    include Fiddle::Win32Types
    typealias "LPVOID", "void*"
    typealias "LPCWSTR", "char*"

    module Successive
      include Enumerable

      def each
        return to_enum(__method__) unless block_given?

        entry = self
        while true
          yield(entry)
          entry = self.class.new(tail)
        end
      end

      def tail
        to_ptr + self.class.size
      end
    end

    # Icon file header
    IconHeader = struct(
      [
        "WORD Reserved",
        "WORD ResourceType",
        "WORD ImageCount"
      ]
    ).include(Successive)

    icon_info = [
      "BYTE Width",
      "BYTE Height",
      "BYTE Colors",
      "BYTE Reserved",
      "WORD Planes",
      "WORD BitsPerPixel",
      "DWORD ImageSize"
    ]

    # Icon File directory entry structure
    IconDirectoryEntry = struct(icon_info + ["DWORD ImageOffset"]).include(Successive)

    # Group Icon Resource directory entry structure
    IconDirResEntry = struct(icon_info + ["WORD ResourceID"]).include(Successive)

    class IconFile < IconHeader
      def initialize(icon_filename)
        @data = File.binread(icon_filename)
        super(Fiddle::Pointer.to_ptr(@data))
      end

      def entries
        IconDirectoryEntry.new(self.tail).take(self.ImageCount)
      end
    end

    class GroupIcon < IconHeader
      attr_reader :size

      def initialize(image_count, resource_type)
        @size = IconHeader.size + image_count * IconDirResEntry.size
        super(Fiddle.malloc(@size), Fiddle::RUBY_FREE)
        self.Reserved = 0
        self.ResourceType = resource_type
        self.ImageCount = image_count
      end

      def entries
        IconDirResEntry.new(self.tail).take(self.ImageCount)
      end
    end

    MAKEINTRESOURCE = -> (i) { Fiddle::Pointer.new(i) }
    RT_ICON = MAKEINTRESOURCE.(3)
    RT_GROUP_ICON = MAKEINTRESOURCE.(RT_ICON.to_i + 11)

    MAKELANGID = -> (p, s) { s << 10 | p }
    LANG_NEUTRAL = 0x00
    SUBLANG_DEFAULT = 0x01
    LANGID = MAKELANGID.(LANG_NEUTRAL, SUBLANG_DEFAULT)

    extern "DWORD GetLastError()"
    extern "HANDLE BeginUpdateResourceW(LPCWSTR, BOOL)"
    extern "BOOL EndUpdateResourceW(HANDLE, BOOL)"
    extern "BOOL UpdateResourceW(HANDLE, LPCWSTR, LPCWSTR, WORD, LPVOID, DWORD)"

    class << self
      def update_icon(executable_filename, icon_filename)
        update_resource(executable_filename) do |handle|
          icon_file = IconFile.new(icon_filename)
          icon_entries = icon_file.entries

          # Create the RT_ICON resources
          icon_entries.each_with_index do |entry, i|
            if UpdateResourceW(handle, RT_ICON, 101 + i, LANGID, icon_file.to_i + entry.ImageOffset, entry.ImageSize) == 0
              raise "failed to UpdateResource(#{GetLastError()})"
            end
          end

          # Create the RT_GROUP_ICON structure
          group_icon = GroupIcon.new(icon_file.ImageCount, icon_file.ResourceType)
          group_icon.entries.zip(icon_entries).each_with_index do |(res, icon), i|
            res.Width = icon.Width
            res.Height = icon.Height
            res.Colors = icon.Colors
            res.Reserved = icon.Reserved
            res.Planes = icon.Planes
            res.BitsPerPixel = icon.BitsPerPixel
            res.ImageSize = icon.ImageSize
            res.ResourceID = 101 + i
          end

          # Save the RT_GROUP_ICON resource
          if UpdateResourceW(handle, RT_GROUP_ICON, 100, LANGID, group_icon, group_icon.size) == 0
            raise "Failed to create group icon(#{GetLastError()})"
          end
        end
      end

      def update_resource(executable_filename)
        handle = BeginUpdateResourceW(executable_filename.encode("UTF-16LE"), 0)
        if handle == Fiddle::NULL
          raise "Failed to BeginUpdateResourceW(#{GetLastError()})"
        end

        yield(handle)

        if EndUpdateResourceW(handle, 0) == 0
          raise "Failed to EndUpdateResourceW(#{GetLastError()})"
        end
      end
    end
  end
end
