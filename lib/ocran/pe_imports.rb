# frozen_string_literal: true

module Ocran
  # Reads the names of the DLLs a PE image (exe, dll, or a Ruby extension
  # .so on Windows) imports, from its import and delay-load import tables.
  # Pure Ruby, so it also works where the image cannot be loaded.
  module PEImports
    IMPORT_DIRECTORY = 1
    DELAY_IMPORT_DIRECTORY = 13

    module_function

    # Returns the imported DLL names in table order, or [] for a file that
    # is not a well-formed PE image.
    def dll_names(path)
      Image.new(File.binread(path)).dll_names
    rescue SystemCallError, RangeError, ArgumentError
      []
    end

    class Image
      def initialize(data)
        @data = data
      end

      def dll_names
        return [] unless @data.byteslice(0, 2) == "MZ"

        pe = u32(0x3c)
        return [] unless @data.byteslice(pe, 4) == "PE\0\0"

        section_count = u16(pe + 6)
        optional_header = pe + 24
        optional_header_size = u16(pe + 20)
        directories, directory_count =
          case u16(optional_header)
          when 0x10b then [optional_header + 96, u32(optional_header + 92)]  # PE32
          when 0x20b then [optional_header + 112, u32(optional_header + 108)] # PE32+
          else return []
          end

        @sections = Array.new(section_count) do |i|
          s = optional_header + optional_header_size + i * 40
          { va: u32(s + 12), size: [u32(s + 8), u32(s + 16)].max, raw: u32(s + 20) }
        end

        names = []
        if directory_count > IMPORT_DIRECTORY
          # IMAGE_IMPORT_DESCRIPTOR: 20 bytes, the DLL name RVA at +12
          each_descriptor(directories + IMPORT_DIRECTORY * 8, 20, 12) { |name| names << name }
        end
        if directory_count > DELAY_IMPORT_DIRECTORY
          # IMAGE_DELAYLOAD_DESCRIPTOR: 32 bytes, the DLL name RVA at +4
          each_descriptor(directories + DELAY_IMPORT_DIRECTORY * 8, 32, 4) { |name| names << name }
        end
        names.uniq(&:downcase)
      end

      private

      def each_descriptor(directory, size, name_field)
        table = offset_of(u32(directory))
        return unless table

        # Never past the table's declared size, in case a malformed image
        # lacks the terminating all-zero descriptor.
        (u32(directory + 4) / size).times do
          name_rva = u32(table + name_field)
          break if name_rva.zero?

          offset = offset_of(name_rva)
          break unless offset

          name = @data.byteslice(offset, 260)&.unpack1("Z*")
          yield name if name && !name.empty?
          table += size
        end
      end

      def offset_of(rva)
        return nil if rva.zero?

        section = @sections.find { |s| rva >= s[:va] && rva < s[:va] + s[:size] }
        section && rva - section[:va] + section[:raw]
      end

      def u16(offset)
        @data.byteslice(offset, 2)&.unpack1("v") or raise RangeError
      end

      def u32(offset)
        @data.byteslice(offset, 4)&.unpack1("V") or raise RangeError
      end
    end
  end
end
