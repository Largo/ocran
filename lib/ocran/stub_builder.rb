# frozen_string_literal: true
require "tempfile"
require_relative "file_path_set"

module Ocran
  # Utility class that produces the actual executable. Opcodes
  # (create_file, mkdir etc) are added by invoking methods on an
  # instance of OcranBuilder.
  #
  # The packed data has two sections:
  #   Bootstrap section: Processed by C stub (Ruby interpreter, launcher,
  #     shared libs, OCRAN_RUBY_PATH). Always uncompressed.
  #   Main section: Processed by Ruby launcher (gems, source files, env vars,
  #     script info). Optionally LZMA compressed.
  #
  # Footer layout (12 bytes):
  #   [main_data_size (4 bytes)] [offset_to_header (4 bytes)] [signature (4 bytes)]
  class StubBuilder
    Signature = [0x41, 0xb6, 0xba, 0x4e].freeze

    OP_CREATE_DIRECTORY = 1
    OP_CREATE_FILE = 2
    OP_SETENV = 3
    OP_SET_SCRIPT = 4
    OP_CREATE_SYMLINK = 5

    DEBUG_MODE          = 0x01
    EXTRACT_TO_EXE_DIR  = 0x02
    AUTO_CLEAN_INST_DIR = 0x04
    CHDIR_BEFORE_SCRIPT = 0x08
    DATA_COMPRESSED     = 0x10

    WINDOWS = Gem.win_platform?

    base_dir = File.expand_path("../../share/ocran", File.dirname(__FILE__))
    STUB_PATH = File.expand_path(WINDOWS ? "stub.exe" : "stub", base_dir)
    STUBW_PATH = WINDOWS ? File.expand_path("stubw.exe", base_dir) : nil
    LZMA_PATH = WINDOWS ? File.expand_path("lzma.exe", base_dir) : nil
    EDICON_PATH = WINDOWS ? File.expand_path("edicon.exe", base_dir) : nil

    def self.find_posix_lzma_cmd
      if system("which lzma > /dev/null 2>&1")
        ["lzma", "--compress", "--stdout"]
      elsif system("which xz > /dev/null 2>&1")
        ["xz", "--format=lzma", "--compress", "--stdout"]
      elsif File.exist?("/opt/homebrew/bin/lzma")
        ["/opt/homebrew/bin/lzma", "--compress", "--stdout"]
      else
        nil
      end
    end

    LZMA_CMD = WINDOWS ? [LZMA_PATH, "e", "-si", "-so"] : find_posix_lzma_cmd

    attr_reader :data_size

    # Clear invalid security directory entries from PE executables
    # This is necessary because some linkers may set non-zero values in the
    # security directory even when there is no actual digital signature
    def self.clear_invalid_security_entry(file_path)
      data = File.binread(file_path)
      return unless data.size > 64 # Minimum PE header size

      # Read DOS header to find PE header offset
      e_lfanew_offset = 60
      pe_offset = data[e_lfanew_offset, 4].unpack1("L")
      return if pe_offset + 160 > data.size # Not enough room for headers

      # Calculate security directory offset
      # PE signature (4) + FILE_HEADER (20) + partial OPTIONAL_HEADER to DataDirectory
      security_entry_offset = pe_offset + 4 + 20 + 128

      # Read security directory entry (VirtualAddress and Size)
      sec_addr = data[security_entry_offset, 4].unpack1("L")
      sec_size = data[security_entry_offset + 4, 4].unpack1("L")

      # Check if security entry is invalid (points beyond file or size is 0)
      if sec_size != 0 && (sec_addr == 0 || sec_addr >= data.size || sec_addr + sec_size > data.size)
        # Clear the invalid security entry
        data[security_entry_offset, 8] = "\x00" * 8
        File.binwrite(file_path, data)
      end
    end

    # chdir_before:
    # When set to true, the working directory is changed to the application's
    # deployment location at runtime.
    #
    # debug_mode:
    # When the debug_mode option is set to true, the stub will output debug information
    # when the exe file is executed. Debug mode can also be enabled within the directive
    # code using the enable_debug_mode method. This option is provided to transition to
    # debug mode from the initialization point of the stub.
    #
    # debug_extract:
    # When set to true, the runtime file is extracted to the directory where the executable resides,
    # and the extracted files remain even after the application exits.
    # When set to false, the runtime file is extracted to the system's temporary directory,
    # and the extracted files are deleted after the application exits.
    #
    # gui_mode:
    # When set to true, the stub does not display a console window at startup. Errors are shown in a dialog window.
    # When set to false, the stub reports errors through the console window.
    #
    # icon_path:
    # Specifies the path to the icon file to be embedded in the stub's resources.
    #
    def initialize(path, chdir_before: nil, debug_extract: nil, debug_mode: nil,
                   enable_compression: nil, gui_mode: nil, icon_path: nil)
      @dirs = FilePathSet.new
      @files = FilePathSet.new
      @data_size = 0
      @enable_compression = enable_compression

      if icon_path && !File.exist?(icon_path)
        raise "Icon file #{icon_path} not found"
      end

      output_dir = File.dirname(path)
      FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)
      stub_tmp = File.join(output_dir, ".ocran_stub_#{$$}_#{Time.now.to_i}")
      stub_src = if gui_mode && WINDOWS
                   STUBW_PATH
                 else
                   STUB_PATH
                 end
      IO.copy_stream(stub_src, stub_tmp)
      stub = stub_tmp

      # Clear any invalid security directory entries from the stub (Windows only)
      self.class.clear_invalid_security_entry(stub) if WINDOWS

      # Embed icon resource (Windows only)
      if icon_path && WINDOWS
        system(EDICON_PATH, stub, icon_path.to_s, exception: true)
      end

      File.open(stub, "ab") do |of|
        @of = of
        @opcode_offset = @of.size

        write_header(debug_mode, debug_extract, chdir_before, enable_compression)

        yield(self)

        finalize_main_section if @main_buffer

        write_footer
      end

      File.rename(stub, path)
      File.chmod(0755, path) unless WINDOWS
    end

    # Marks the end of the bootstrap section. All subsequent opcodes will be
    # written to a temporary buffer for the main section, which is processed
    # by the Ruby launcher at runtime instead of the C stub.
    def end_bootstrap
      @main_buffer = Tempfile.new(["ocran_main", ".bin"])
      @main_buffer.binmode
      @bootstrap_of = @of
      @of = @main_buffer
    end

    def mkdir(target)
      return unless @dirs.add?("/", target)

      write_opcode(OP_CREATE_DIRECTORY)
      write_path(target)
    end

    def symlink(link_path, target)
      write_opcode(OP_CREATE_SYMLINK)
      write_path(link_path)
      write_string(target.to_s)
    end

    def cp(source, target)
      unless File.exist?(source)
        raise "The file does not exist (#{source})"
      end

      return unless @files.add?(source, target)

      write_opcode(OP_CREATE_FILE)
      write_path(target)
      write_file(source)
    end

    # Specifies the final application script to be launched, which can be called
    # from any position in the data stream. It cannot be specified more than once.
    #
    # You can omit setting OP_SET_SCRIPT without issues, in which case
    # the stub terminates without launching anything after performing other
    # runtime operations.
    def exec(image, script, *argv)
      if @script_set
        raise "Script is already set"
      end
      @script_set = true

      write_opcode(OP_SET_SCRIPT)
      write_string_array(convert_to_native(image), convert_to_native(script), *argv)
    end

    def export(name, value)
      write_opcode(OP_SETENV)
      write_string(name.to_s)
      write_string(value.to_s)
    end

    private

    def finalize_main_section
      @main_buffer.flush
      @of = @bootstrap_of

      if @enable_compression && LZMA_CMD
        compress_main_section
      else
        @main_buffer.rewind
        @main_file_size = IO.copy_stream(@main_buffer, @of)
      end

      @main_buffer.close!
    end

    def compress_main_section
      @main_buffer.rewind
      uncompressed_size = @main_buffer.size
      lzma_start_pos = @of.pos

      IO.popen(LZMA_CMD, "r+b") do |lzma|
        writer = Thread.new { IO.copy_stream(@main_buffer, lzma); lzma.close_write }
        @main_file_size = IO.copy_stream(lzma, @of)
        writer.join
      end

      # Patch the LZMA uncompressed size in the header
      # LZMA format: 5 bytes properties + 8 bytes uncompressed size
      File.binwrite(@of.path, [uncompressed_size].pack("Q<"), lzma_start_pos + 5)
    end

    def write_header(debug_mode, debug_extract, chdir_before, compressed)
      next_to_exe, delete_after = debug_extract, !debug_extract
      @of << [0 |
                (debug_mode ? DEBUG_MODE : 0) |
                (next_to_exe ? EXTRACT_TO_EXE_DIR : 0) |
                (delete_after ? AUTO_CLEAN_INST_DIR : 0) |
                (chdir_before ? CHDIR_BEFORE_SCRIPT : 0) |
                (compressed ? DATA_COMPRESSED : 0)
      ].pack("C")
    end

    def write_opcode(op)
      @of << [op].pack("C")
      @data_size += 1
    end

    def write_size(i)
      if i > 0xFFFF_FFFF
        raise ArgumentError, "Size #{i} is too large: must be 32-bit unsigned integer (0 to 4294967295)"
      end

      @of << [i].pack("V")
      @data_size += 4
    end

    def write_string(str)
      len = str.bytesize + 1 # +1 to account for the null terminator

      if len > 0xFFFF
        raise ArgumentError, "String length #{len} is too large: must be less than or equal to 65535 bytes including null terminator"
      end

      write_size(len)
      @of << [str].pack("Z*")
      @data_size += len
    end

    def write_string_array(*str_array)
      ary = str_array.map(&:to_s)

      if ary.any?(&:empty?)
         raise ArgumentError, "Argument list must not contain empty strings"
      end

      # Append an empty string so that when joined with "\0", the final buffer
      # ends in two consecutive NUL bytes (double–NUL terminator) to mark end-of-list.
      ary << ""

      size = ary.sum(0) { |s| s.bytesize + 1 }
      write_size(size)
      ary.each_slice(1) { |a| @of << a.pack("Z*") }
      @data_size += size
    end

    def write_file(src)
      size = File.size(src)
      write_size(size)
      IO.copy_stream(src, @of)
      @data_size += size
    end

    def write_path(path)
      write_string(convert_to_native(path))
    end

    def write_footer
      main_size = @main_file_size || 0
      @of << [main_size, @opcode_offset].pack("VV")
      @of << Signature.pack("C*")
    end

    def convert_to_native(path)
      WINDOWS ? path.to_s.tr(File::SEPARATOR, "\\") : path.to_s
    end
  end
end
