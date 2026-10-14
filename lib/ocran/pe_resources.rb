# frozen_string_literal: true
require_relative "ed_resource_builder"

module Ocran
  # Reads and rewrites the resources of a PE executable in pure Ruby, so that
  # icons and version information can be set on any build host - the
  # Windows API OCRAN uses for the stub (BeginUpdateResource) exists only on
  # Windows. Used for --static-runtime, whose executable is a copy of the runtime.
  #
  # The resource tree is a Hash: type => { name => { language => data } },
  # where types and names are Integers (IDs) or Strings. #write puts the
  # rebuilt tree into a new section at the end of the image and points the
  # resource data directory at it; the old resource section stays where it
  # is, unused (renamed .rsrc_o), so no other section has to move.
  class PeResources
    RT_ICON = 3
    RT_STRING = 6
    RT_GROUP_ICON = 14
    RT_VERSION = 16
    RT_MANIFEST = 24
    SECTION_CHARACTERISTICS = 0x40000040 # initialized data, readable

    attr_reader :tree

    def initialize(bytes)
      @bytes = bytes.b
      parse_headers
      @tree = read_tree
    end

    def self.update(path)
      pe = new(File.binread(path))
      yield pe
      File.binwrite(path, pe.to_bytes)
    end

    # Replaces the icon(s) with the images of an .ico file.
    def set_icon(ico_data)
      ico = ico_data.b
      reserved, type, count = ico.unpack("vvv")
      raise "not an icon file" unless reserved.zero? && type == 1 && count.positive?

      icons = {}
      group = [0, 1, count].pack("vvv")
      count.times do |i|
        w, h, colors, res, planes, bits, size, offset = ico.unpack("CCCCvvVV", offset: 6 + i * 16)
        icons[i + 1] = { EdResource::LANGID => ico.byteslice(offset, size) }
        group << [w, h, colors, res, planes, bits, size, i + 1].pack("CCCCvvVv")
      end
      @tree[RT_ICON] = icons
      @tree[RT_GROUP_ICON] = { 1 => { EdResource::LANGID => group } }
    end

    def set_version_info(blob)
      @tree[RT_VERSION] = { 1 => { EdResource::LANGID => blob.b } }
    end

    def manifest
      @tree.dig(RT_MANIFEST, 1)&.values&.first
    end

    def set_manifest(xml)
      @tree[RT_MANIFEST] = { 1 => { EdResource::LANGID => xml.b } }
    end

    def set_strings(id_to_value)
      table = (@tree[RT_STRING] ||= {})
      id_to_value.group_by { |id, _| id.to_i / 16 }.each do |bundle, pairs|
        table[bundle + 1] = { EdResource::LANGID => EdResource::Build.string_bundle(pairs.to_h) }
      end
    end

    def to_bytes
      out = @bytes.dup
      rva = align(@sections.map { |s| s[:va] + [s[:vsize], s[:rsize]].max }.max, @section_align)
      section = build_tree(rva)
      raw_size = align(section.bytesize, @file_align)
      raw_at = align(@sections.map { |s| s[:raw] + s[:rsize] }.max, @file_align)
      table_at = @section_table + @sections.size * 40
      raise "no room in the PE header for another section" if table_at + 40 > @size_of_headers

      out = out.byteslice(0, raw_at).ljust(raw_at, "\0".b)
      out << section << ("\0".b * (raw_size - section.bytesize))
      header = [".rsrc".b.ljust(8, "\0".b), section.bytesize, rva, raw_size, raw_at, 0, 0, 0, 0,
                SECTION_CHARACTERISTICS].pack("a8VVVVVVvvV")
      out[table_at, 40] = header
      out[@pe + 6, 2] = [@sections.size + 1].pack("v")
      out[@optional + 56, 4] = [align(rva + section.bytesize, @section_align)].pack("V") # SizeOfImage
      out[@optional + 64, 4] = [0].pack("V") # CheckSum: not checked for user-mode executables
      out[@data_dirs + 16, 8] = [rva, section.bytesize].pack("VV")
      if (old = @sections.find { |s| s[:va] == @resource_rva })
        out[old[:header], 8] = ".rsrc_o".b.ljust(8, "\0".b)
      end
      out
    end

    private

    def align(value, to) = (value + to - 1) / to * to

    def parse_headers
      raise "not a PE executable" unless @bytes.start_with?("MZ")

      @pe = @bytes.unpack1("V", offset: 0x3c)
      raise "not a PE executable" unless @bytes.byteslice(@pe, 4) == "PE\0\0".b

      count = @bytes.unpack1("v", offset: @pe + 6)
      size_of_optional = @bytes.unpack1("v", offset: @pe + 20)
      @optional = @pe + 24
      pe32_plus = @bytes.unpack1("v", offset: @optional) == 0x20b
      @section_align, @file_align = @bytes.unpack("VV", offset: @optional + 32)
      @size_of_headers = @bytes.unpack1("V", offset: @optional + 60)
      @data_dirs = @optional + (pe32_plus ? 112 : 96)
      @resource_rva, @resource_size = @bytes.unpack("VV", offset: @data_dirs + 16)
      @section_table = @optional + size_of_optional
      @sections = (0...count).map do |i|
        at = @section_table + i * 40
        vsize, va, rsize, raw = @bytes.unpack("VVVV", offset: at + 8)
        { header: at, vsize: vsize, va: va, rsize: rsize, raw: raw }
      end
    end

    def rva_to_offset(rva)
      s = @sections.find { |sec| rva >= sec[:va] && rva < sec[:va] + [sec[:vsize], sec[:rsize]].max }
      raise "RVA #{rva} is in no section" unless s

      rva - s[:va] + s[:raw]
    end

    def read_tree
      return {} if @resource_rva.zero?

      @root = rva_to_offset(@resource_rva)
      read_directory(0, 3)
    end

    def read_directory(offset, depth)
      at = @root + offset
      named, ids = @bytes.unpack("vv", offset: at + 12)
      (0...(named + ids)).to_h do |i|
        name, target = @bytes.unpack("VV", offset: at + 16 + i * 8)
        key = name & 0x80000000 != 0 ? read_name(name & 0x7fffffff) : name
        value =
          if target & 0x80000000 != 0
            read_directory(target & 0x7fffffff, depth - 1)
          else
            data_rva, size = @bytes.unpack("VV", offset: @root + target)
            @bytes.byteslice(rva_to_offset(data_rva), size)
          end
        [key, value]
      end
    end

    def read_name(offset)
      length = @bytes.unpack1("v", offset: @root + offset)
      @bytes.byteslice(@root + offset + 2, length * 2).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
    end

    # Serializes the tree the way resource compilers lay it out: all
    # directories, then name strings, then data entries, then the data.
    def build_tree(rva)
      levels = []
      collect = lambda do |node, depth|
        dir = { entries: sort_entries(node) }
        levels << dir
        dir[:entries].each do |entry|
          entry[:child] = depth < 2 ? collect.(entry[:value], depth + 1) : { leaf: entry[:value] }
        end
        dir
      end
      root = collect.(@tree, 0)

      offset = 0
      levels.each { |d| d[:offset] = offset; offset += 16 + d[:entries].size * 8 }
      names = {}
      levels.each do |d|
        d[:entries].each do |e|
          next unless e[:key].is_a?(String)

          names[e[:key]] ||= begin
            at = offset
            offset += 2 + e[:key].encode(Encoding::UTF_16LE).bytesize
            at
          end
        end
      end
      offset = align(offset, 4)
      leaves = levels.flat_map { |d| d[:entries].map { |e| e[:child] } }.select { |c| c[:leaf] }
      leaves.each { |l| l[:entry] = offset; offset += 16 }
      leaves.each { |l| offset = align(offset, 8); l[:data] = offset; offset += l[:leaf].bytesize }

      out = "\0".b * offset
      levels.each do |d|
        named = d[:entries].count { |e| e[:key].is_a?(String) }
        out[d[:offset], 16] = [0, 0, 0, 0, named, d[:entries].size - named].pack("VVvvvv")
        d[:entries].each_with_index do |e, i|
          name = e[:key].is_a?(String) ? 0x80000000 | names[e[:key]] : e[:key]
          target = e[:child][:leaf] ? e[:child][:entry] : 0x80000000 | e[:child][:offset]
          out[d[:offset] + 16 + i * 8, 8] = [name, target].pack("VV")
        end
      end
      names.each do |name, at|
        utf16 = name.encode(Encoding::UTF_16LE).b
        out[at, 2 + utf16.bytesize] = [utf16.bytesize / 2].pack("v") + utf16
      end
      leaves.each do |l|
        out[l[:entry], 16] = [rva + l[:data], l[:leaf].bytesize, 0, 0].pack("VVVV")
        out[l[:data], l[:leaf].bytesize] = l[:leaf]
      end
      out
    end

    # Named entries first, in case-insensitive order, then IDs ascending,
    # as Windows' binary search through a directory expects.
    def sort_entries(node)
      named, ids = node.partition { |k, _| k.is_a?(String) }
      (named.sort_by { |k, _| k.upcase } + ids.sort_by(&:first)).map { |k, v| { key: k, value: v } }
    end
  end
end
