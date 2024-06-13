module Ocran
  # Utility class that produces the actual executable. Opcodes
  # (create_file, mkdir etc) are added by invoking methods on an
  # instance of OcranBuilder.
  class StubBuilder
    Signature = [0x41, 0xb6, 0xba, 0x4e].freeze
    OP_END = 0
    OP_CREATE_DIRECTORY = 1
    OP_CREATE_FILE = 2
    OP_SETENV = 3
    OP_SET_SCRIPT = 4

    DEBUG_MODE          = 0x01
    EXTRACT_TO_EXE_DIR  = 0x02
    AUTO_CLEAN_INST_DIR = 0x04
    CHDIR_BEFORE_SCRIPT = 0x08
    DATA_COMPRESSED     = 0x10

    base_dir = File.join(File.dirname(__FILE__), "../../share/ocran")
    STUB_PATH = File.join(base_dir, "stub.exe")
    STUBW_PATH = File.join(base_dir, "stubw.exe")
    LZMA_PATH = File.join(base_dir, "lzma.exe")
    EDICON_PATH = File.join(base_dir, "edicon.exe")

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
                   enable_compression: nil, gui_mode: nil, icon_path: nil, &b)
      @paths = {}
      @files = {}

      stub_path = Pathname.new(gui_mode ? STUBW_PATH : STUB_PATH)

      unless stub_path.exist?
        Ocran.fatal_error "Stub image not available"
      end

      File.binwrite(path, stub_path.binread)

      begin
        if icon_path
          system(EDICON_PATH, path.to_s, icon_path.to_s, exception: true)
        end

        @opcode_offset = File.size(path)

        File.open(path, "ab") do |ocran_file|
          @data_size = 0
          @of = ocran_file

          if debug_mode
            Ocran.msg("Enabling debug mode in executable")
          end

          next_to_exe, delete_after = debug_extract, !debug_extract
          write_header(debug_mode, next_to_exe, delete_after, chdir_before, enable_compression)

          b = proc {
            yield(self)
            write_opcode(OP_END)
          }

          if enable_compression
            compress(&b)
          else
            b.yield
          end

          close
        end
      rescue Exception => e
        File.unlink(path) if File.exist?(path)
        Ocran.fatal_error("Stub building failed: #{e.message}")
      end
    end

    def mkdir(path)
      return if path.to_s == "."

      key = path.to_s.downcase
      return if @paths[key]

      @paths[key] = path

      write_opcode(OP_CREATE_DIRECTORY)
      write_path(path)
    end

    def cp(src, tgt)
      unless File.exist?(src)
        raise "The file does not exist (#{src})"
      end

      key = tgt.to_s.downcase
      return if @files[key]

      @files[key] = [tgt, src]

      write_opcode(OP_CREATE_FILE)
      write_path(tgt)
      write_file(src)
    end

    def touch(tgt)
      src = File.expand_path("touch_placeholder", __dir__)
      cp(src, tgt)
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

    def close
      @of << ([@opcode_offset] + Signature).pack("VC*")
      @of.close
    end

    def compress
      IO.popen([LZMA_PATH, "e", "-si", "-so"], "r+b") do |lzma|
        _of, @of = @of, lzma
        Thread.new { yield(self); lzma.close_write }
        IO.copy_stream(lzma, _of)
        @of = _of
      end

      Ocran.msg "After decompression, the data will expand to #{@data_size} bytes."
      # Calculate the position to write the LZMA decompressed size (64-bit unsigned integer)
      # @opcode_offset: start position of the data section
      # 1: size of the header byte
      # 5: size of the LZMA header in bytes
      File.binwrite(@of.path, [@data_size].pack("Q<"), @opcode_offset + 1 + 5)
    end
    private :compress

    def write_header(debug_mode, next_to_exe, delete_after, chdir_before, compressed)
      @of << [0 |
                (debug_mode ? DEBUG_MODE : 0) |
                (next_to_exe ? EXTRACT_TO_EXE_DIR : 0) |
                (delete_after ? AUTO_CLEAN_INST_DIR : 0) |
                (chdir_before ? CHDIR_BEFORE_SCRIPT : 0) |
                (compressed ? DATA_COMPRESSED : 0)
      ].pack("C")
    end
    private :write_header

    def write_opcode(op)
      @of << [op].pack("C")
      @data_size += 1
    end
    private :write_opcode

    def write_size(i)
      if i > 0xFFFF_FFFF
        raise ArgumentError, "Size #{i} is too large: must be 32-bit unsigned integer (0 to 4294967295)"
      end

      @of << [i].pack("V")
      @data_size += 4
    end
    private :write_size

    def write_string(str)
      len = str.bytesize + 1 # +1 to account for the null terminator

      if len > 0xFFFF
        raise ArgumentError, "String length #{len} is too large: must be less than or equal to 65535 bytes including null terminator"
      end

      @of << [len, str].pack("vZ*")
      @data_size += 2 + len
    end
    private :write_string

    def write_string_array(*str_array)
      ary = str_array.map(&:to_s)
      size = ary.sum(0) { |s| s.bytesize + 1 }
      write_size(size)
      ary.each_slice(1) { |a| @of << a.pack("Z*") }
      @data_size += size
    end
    private :write_string_array

    def write_file(src)
      size = File.size(src)
      write_size(size)
      IO.copy_stream(src, @of)
      @data_size += size
    end
    private :write_file

    def write_path(path)
      write_string(convert_to_native(path))
    end

    def convert_to_native(path)
      path.to_s.tr(File::SEPARATOR, "\\")
    end
    private :convert_to_native
  end
end
