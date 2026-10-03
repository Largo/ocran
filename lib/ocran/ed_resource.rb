# frozen_string_literal: true
require "fiddle/import"
require "fiddle/types"
# The language/codepage constants and the pure-Ruby blob builder live in a
# separate, dlload-free file so they can be unit-tested on any platform.
require_relative "ed_resource_builder"

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

    # Language/codepage constants (MAKELANGID, LANGID, LANGID_US_ENGLISH,
    # CODEPAGE_UNICODE, STRING_TABLE_KEY) are defined in ed_resource_builder.rb,
    # required above.

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
