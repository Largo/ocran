# frozen_string_literal: true
require "fiddle/import"
require "fiddle/types"

module Ocran
  # Edits PE resources in an executable, in the style of rcedit:
  #   * RT_VERSION  - version info (VS_VERSIONINFO / VS_FIXEDFILEINFO / StringFileInfo)
  #   * RT_MANIFEST - application manifest / requested execution level
  #   * RT_STRING   - string table entries by numeric ID
  #
  # This is a sibling of EdIcon and uses the same Windows resource-update API
  # (BeginUpdateResourceW / UpdateResourceW / EndUpdateResourceW) via Fiddle.
  module EdResource
    extend Fiddle::Importer
    dlload "kernel32.dll"

    include Fiddle::Win32Types
    typealias "LPVOID", "void*"
    typealias "LPCWSTR", "char*"

    MAKEINTRESOURCE = -> (i) { Fiddle::Pointer.new(i) }
    RT_VERSION = MAKEINTRESOURCE.(16)
    RT_STRING = MAKEINTRESOURCE.(6)
    # CREATEPROCESS_MANIFEST_RESOURCE_ID == 1; the manifest is stored under
    # resource type RT_MANIFEST (24), name id 1.
    RT_MANIFEST = MAKEINTRESOURCE.(24)
    MANIFEST_RESOURCE_ID = 1

    MAKELANGID = -> (p, s) { s << 10 | p }
    LANG_ENGLISH = 0x09
    SUBLANG_ENGLISH_US = 0x01

    # US English / Unicode. Resources are written under this language id so the
    # manifest write replaces (rather than duplicates) the stub's compiled-in
    # RT_MANIFEST, which windres stores under 0x0409. The same id is used for the
    # StringTable key ("040904B0") and the VarFileInfo Translation value (langid
    # in the low word, codepage in the high word).
    LANGID_US_ENGLISH = MAKELANGID.(LANG_ENGLISH, SUBLANG_ENGLISH_US) # 0x0409
    LANGID = LANGID_US_ENGLISH
    CODEPAGE_UNICODE = 0x04B0
    STRING_TABLE_KEY = format("%04X%04X", LANGID_US_ENGLISH, CODEPAGE_UNICODE)

    EXECUTION_LEVELS = %w[asInvoker highestAvailable requireAdministrator].freeze

    # Baseline manifest, copied verbatim from src/stub.manifest. Inlined as a
    # constant so the installed gem has no runtime dependency on the src tree.
    MANIFEST_TEMPLATE = <<~MANIFEST
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
          <security>
            <requestedPrivileges>
              <requestedExecutionLevel level="asInvoker"/>
            </requestedPrivileges>
          </security>
        </trustInfo>
        <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
          <application>
            <!--The ID below indicates application support for Windows Vista -->
            <supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}"/>
            <!--The ID below indicates application support for Windows 7 -->
            <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
            <!--The ID below indicates application support for Windows 8 -->
            <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
            <!--The ID below indicates application support for Windows 8.1 -->
            <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
            <!--The ID below indicates application support for Windows 10 -->
            <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
          </application>
        </compatibility>
        <application>
          <windowsSettings>
            <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
          </windowsSettings>
        </application>
      </assembly>
    MANIFEST

    extern "DWORD GetLastError()"
    extern "HANDLE BeginUpdateResourceW(LPCWSTR, BOOL)"
    extern "BOOL EndUpdateResourceW(HANDLE, BOOL)"
    extern "BOOL UpdateResourceW(HANDLE, LPCWSTR, LPCWSTR, WORD, LPVOID, DWORD)"

    # Builds the binary blobs (VS_VERSIONINFO, RT_STRING bundles) that Windows
    # expects. All structures are little-endian.
    module Build
      module_function

      NUL16 = [0].pack("v").freeze

      # UTF-16LE, NUL-terminated, as a binary string.
      def wsz(str)
        str.to_s.encode("UTF-16LE").b + NUL16
      end

      NODE_HEADER_SIZE = 6 # wLength + wValueLength + wType, three WORDs

      # A generic VS_VERSIONINFO node: a 6-byte header (wLength, wValueLength,
      # wType) followed by a NUL-terminated UTF-16LE key, DWORD-aligned Value,
      # then DWORD-aligned children.
      #
      # Padding aligns Value and each child to a 32-bit boundary relative to the
      # start of the node, so the NODE_HEADER_SIZE prefix is included when
      # computing pad lengths. (Each node itself starts on a 4-byte boundary
      # because parents pad before appending children, and the whole blob is
      # placed at an aligned resource offset.)
      #
      # value_len is stored verbatim in wValueLength: callers pass bytes for
      # binary values and WORD counts for string values (the Win32 quirk).
      def node(key:, wtype:, value: nil, value_len: 0, children: [])
        body = +"".b
        pad = -> { body << ("\x00".b * ((-(NODE_HEADER_SIZE + body.bytesize)) & 3)) }

        body << wsz(key)
        pad.call
        body << value if value
        unless children.empty?
          pad.call
          children.each do |c|
            pad.call
            body << c
          end
        end
        wlength = NODE_HEADER_SIZE + body.bytesize
        [wlength, value_len, wtype].pack("vvv") + body
      end

      # Split "X.Y.Z.W" into four integers, padding/truncating to 4.
      def quad(ver)
        parts = ver.to_s.split(".").map(&:to_i)
        parts.fill(0, parts.size...4)[0, 4]
      end

      # VS_FIXEDFILEINFO (52 bytes).
      def fixed_file_info(file_ver, prod_ver)
        fa, fb, fc, fd = quad(file_ver)
        pa, pb, pc, pd = quad(prod_ver)
        [
          0xFEEF04BD,         # dwSignature
          0x00010000,         # dwStrucVersion (1.0)
          (fa << 16) | fb,    # dwFileVersionMS
          (fc << 16) | fd,    # dwFileVersionLS
          (pa << 16) | pb,    # dwProductVersionMS
          (pc << 16) | pd,    # dwProductVersionLS
          0x0000003F,         # dwFileFlagsMask
          0x00000000,         # dwFileFlags
          0x00000004,         # dwFileOS = VOS__WINDOWS32
          0x00000001,         # dwFileType = VFT_APP
          0x00000000,         # dwFileSubtype
          0x00000000,         # dwFileDateMS
          0x00000000          # dwFileDateLS
        ].pack("V13")
      end

      # One String node. wValueLength is in UTF-16 code units (WORDs),
      # including the NUL terminator.
      def string_node(key, value)
        v = wsz(value)
        node(key: key, wtype: 1, value: v, value_len: v.bytesize / 2)
      end

      # Build the full VS_VERSIONINFO blob for RT_VERSION.
      def version_info(strings:, file_version:, product_version:)
        str_children = strings.map { |k, v| string_node(k.to_s, v) }
        string_table = node(key: STRING_TABLE_KEY, wtype: 1, children: str_children)
        string_file_info = node(key: "StringFileInfo", wtype: 1, children: [string_table])

        translation = node(
          key: "Translation", wtype: 0,
          value: [(CODEPAGE_UNICODE << 16) | LANGID_US_ENGLISH].pack("V"),
          value_len: 4
        )
        var_file_info = node(key: "VarFileInfo", wtype: 1, children: [translation])

        ffi = fixed_file_info(file_version, product_version)
        node(
          key: "VS_VERSION_INFO", wtype: 0, value: ffi, value_len: ffi.bytesize,
          children: [string_file_info, var_file_info]
        )
      end

      # Build one RT_STRING bundle (16 slots). id_to_value contains only IDs
      # belonging to this bundle. Each entry is a WORD length (in WORDs, no NUL
      # terminator) followed by the UTF-16LE characters; empty slots are 0x0000.
      def string_bundle(id_to_value)
        slots = Array.new(16) { NUL16.dup }
        id_to_value.each do |id, value|
          u = value.to_s.encode("UTF-16LE").b
          slots[id.to_i % 16] = [u.bytesize / 2].pack("v") + u
        end
        slots.join.b
      end
    end

    class << self
      # Perform every requested resource edit under a single
      # BeginUpdateResource/EndUpdateResource cycle (one PE rewrite).
      def update(executable_filename, version_strings: nil, file_version: nil,
                 product_version: nil, resource_strings: nil, manifest_xml: nil,
                 execution_level: nil)
        wants_version = !blank?(version_strings) || file_version || product_version
        wants_manifest = manifest_xml || execution_level
        wants_strings = !blank?(resource_strings)
        return unless wants_version || wants_manifest || wants_strings

        update_resource(executable_filename) do |handle|
          write_version_info(handle, version_strings || {}, file_version, product_version) if wants_version
          write_manifest(handle, manifest_xml, execution_level) if wants_manifest
          write_resource_strings(handle, resource_strings) if wants_strings
        end
      end

      private

      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def write_version_info(handle, strings, file_version, product_version)
        merged = {}
        strings.each { |k, v| merged[k.to_s] = v }
        merged["FileVersion"] = file_version if file_version
        merged["ProductVersion"] = product_version if product_version

        blob = Build.version_info(
          strings: merged,
          file_version: file_version || merged["FileVersion"] || "0.0.0.0",
          product_version: product_version || merged["ProductVersion"] || "0.0.0.0"
        )
        put(handle, RT_VERSION, 1, blob)
      end

      def write_manifest(handle, manifest_xml, execution_level)
        xml = manifest_xml || MANIFEST_TEMPLATE
        if execution_level
          unless EXECUTION_LEVELS.include?(execution_level)
            raise "Invalid requested execution level: #{execution_level}"
          end
          xml = xml.sub(/level="[^"]*"/, %(level="#{execution_level}"))
        end
        put(handle, RT_MANIFEST, MANIFEST_RESOURCE_ID, xml.b)
      end

      def write_resource_strings(handle, id_to_value)
        id_to_value.group_by { |id, _| id.to_i / 16 }.each do |bundle_index, pairs|
          bundle = Build.string_bundle(pairs.to_h)
          put(handle, RT_STRING, bundle_index + 1, bundle)
        end
      end

      def put(handle, type, name, data)
        name_arg = name.is_a?(Integer) ? MAKEINTRESOURCE.(name) : name
        if UpdateResourceW(handle, type, name_arg, LANGID, data, data.bytesize) == 0
          raise "Failed to UpdateResourceW(#{GetLastError()})"
        end
      end

      def update_resource(executable_filename)
        path = File.expand_path(executable_filename).encode("UTF-16LE").b + "\x00\x00".b
        handle = BeginUpdateResourceW(path, 0)
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
