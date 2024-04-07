require "fiddle/import"
require "fiddle/types"

module Ocran
  module LibraryDetector
    # Windows API functions for handling files may return long paths,
    # with a maximum character limit of 32,767.
    # "\\?\" prefix(4 characters) + long path(32762 characters) + NULL = 32767 characters
    # https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
    MAX_PATH = 32767

    # The byte size of the buffer given as an argument to the EnumProcessModules function.
    # This buffer is used to store the handles of the loaded modules.
    # If the buffer size is smaller than the number of loaded modules,
    # it will automatically increase the buffer size and call the EnumProcessModules function again.
    # Increasing the initial buffer size can reduce the number of iterations required.
    # https://learn.microsoft.com/en-us/windows/win32/psapi/enumerating-all-modules-for-a-process
    DEFAULT_HMODULE_BUFFER_SIZE = 1024

    extend Fiddle::Importer
    dlload "kernel32.dll", "psapi.dll"

    include Fiddle::Win32Types
    # https://docs.microsoft.com/en-us/windows/win32/winprog/windows-data-types
    typealias "HINSTANCE", "HANDLE" # for Ruby2.6 only
    typealias "HMODULE", "HINSTANCE"
    typealias "LPDWORD", "PDWORD"
    typealias "LPWSTR", "char*"

    extern "BOOL EnumProcessModules(HANDLE, HMODULE*, DWORD, LPDWORD)"
    extern "DWORD GetModuleFileNameW(HMODULE, LPWSTR, DWORD)"
    extern "HANDLE GetCurrentProcess()"
    extern "DWORD GetLastError()"

    class << self
      def loaded_dlls
        dword = "L" # A DWORD is a 32-bit unsigned integer.
        bytes_needed = [0].pack(dword)
        bytes = DEFAULT_HMODULE_BUFFER_SIZE
        process_handle = GetCurrentProcess()
        handles = while true
                    buffer = "\x00" * bytes
                    if EnumProcessModules(process_handle, buffer, buffer.bytesize, bytes_needed) == 0
                      Ocran.fatal_error "LibraryDetector: EnumProcessModules failed with error code %d" % GetLastError()
                    end
                    bytes = bytes_needed.unpack1(dword)
                    if bytes <= buffer.bytesize
                      break buffer.unpack("J#{bytes / Fiddle::SIZEOF_VOIDP}")
                    end
                  end
        str = "\x00".encode("UTF-16LE") * MAX_PATH
        handles.map do |handle|
          length = GetModuleFileNameW(handle, str, str.bytesize)
          if length == 0
            Ocran.fatal_error "LibraryDetector: GetModuleFileNameW failed with error code %d" % GetLastError()
          end
          str[0, length].encode("UTF-8")
        end
      end
    end
  end
end
