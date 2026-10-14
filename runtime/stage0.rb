# ocran static runtime, stage 0. Compiled into the runtime executable and
# run (as `ruby -e`) before anything else. Nothing is loaded from disk
# here: $LOAD_PATH is cleared first so a file planted next to the
# executable can never be picked up.
#
# The application is a ZIP archive appended to the executable, with
# offsets relative to the start of the file, so `unzip -l app.exe` or
# 7-Zip list exactly what will run. Stage 0 only indexes that archive
# and evaluates ocran/boot.rb from it; boot.rb (written by ocran at
# packaging time) installs the read-only virtual filesystem and starts
# the application.
# ($LOADED_FEATURES is left alone: at this point it only lists features
# the interpreter provides itself, such as set.rb and enumerator.so.)
$LOAD_PATH.clear
require "zlib" # statically linked, never searched on disk

module OcranRuntime
  EXE = File.expand_path(ENV.fetch("OCRAN_EXECUTABLE")).freeze
  Entry = Struct.new(:name, :method, :crc, :csize, :size, :local_offset)

  @io = File.open(EXE, "rb")
  # One handle for every thread: a seek and its reads must not interleave.
  @io_lock = Thread::Mutex.new

  class << self
    attr_reader :entries

    # Returns the contents of archive member +name+ (binary), or nil.
    def read(name)
      e = @entries[name] or return nil
      data = @io_lock.synchronize do
        @io.pos = e.local_offset
        sig, _, _, _, _, _, _, _, _, nlen, xlen = @io.read(30).unpack("VvvvvvVVVvv")
        raise "ocran: bad local header for #{name}" unless sig == 0x04034b50
        @io.pos = e.local_offset + 30 + nlen + xlen
        @io.read(e.csize)
      end
      data = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data) if e.method == 8
      raise "ocran: unsupported compression for #{name}" unless e.method == 0 || e.method == 8
      raise "ocran: CRC mismatch for #{name}" unless Zlib.crc32(data) == e.crc
      data
    end

    # [file offset, size] of a section of this Mach-O executable.
    def macho_section(segment, section)
      @io.pos = 16
      ncmds, = @io.read(8).unpack("V")
      at = 32
      ncmds.times do
        @io.pos = at
        cmd, cmdsize = @io.read(8).unpack("VV")
        if cmd == 0x19 # LC_SEGMENT_64
          @io.pos = at + 64
          nsects = @io.read(4).unpack1("V")
          nsects.times do |i|
            @io.pos = at + 72 + i * 80
            sectname, segname, _addr, size, offset = @io.read(52).unpack("Z16Z16QQV")
            return [offset, size] if segname == segment && sectname == section
          end
        end
        at += cmdsize
      end
      nil
    end

    def index
      # Where the archive is: appended to the executable, so it ends at the
      # end of the file - or, in a signed Windows executable, where the
      # Authenticode certificate table starts (a signer appends it after our
      # data). On macOS it is the section __OCRAN,__zip (appended data would
      # break the code signature), and its offsets count from that section.
      stop = @io.size
      @base = 0
      @io.pos = 0
      magic = @io.read(4)
      if magic == "\xCF\xFA\xED\xFE".b # Mach-O, 64-bit
        section = macho_section("__OCRAN", "__zip") or raise "ocran: no __OCRAN,__zip section in #{EXE}"
        @base, size = section
        stop = @base + size
      elsif magic.start_with?("MZ")
        @io.pos = 0x3c
        pe = @io.read(4).unpack1("V")
        @io.pos = pe + 24
        ddir = pe + 24 + (@io.read(2).unpack1("v") == 0x20b ? 112 : 96)
        @io.pos = ddir + 4 * 8 # IMAGE_DIRECTORY_ENTRY_SECURITY
        cert_offset, = @io.read(8).unpack("VV")
        stop = cert_offset unless cert_offset.zero?
      end

      tail_start = [stop - 65_557, 0].max
      @io.pos = tail_start
      tail = @io.read(stop - tail_start)
      eocd = tail.rindex("PK\x05\x06".b) or raise "ocran: no application archive in #{EXE}"
      count, cd_size, cd_offset = tail.byteslice(eocd + 10, 10).unpack("vVV")

      @io.pos = @base + cd_offset
      cd = @io.read(cd_size)
      @entries = {}
      pos = 0
      count.times do
        sig, _, _, flags, method, _, _, crc, csize, size, nlen, xlen, clen, _, _, _, offset =
          cd.byteslice(pos, 46).unpack("VvvvvvvVVVvvvvvVV")
        raise "ocran: corrupt central directory" unless sig == 0x02014b50
        raise "ocran: encrypted entries are not supported" if flags & 1 == 1
        name = cd.byteslice(pos + 46, nlen).force_encoding(Encoding::UTF_8)
        @entries[name] = Entry.new(name, method, crc, csize, size, @base + offset).freeze
        pos += 46 + nlen + xlen + clen
      end
      @entries.freeze
    end
  end

  index
  boot = read("ocran/boot.rb") or raise "ocran: ocran/boot.rb missing from #{EXE}"
  TOPLEVEL_BINDING.eval(boot.force_encoding(Encoding::UTF_8), "#{EXE}/ocran/boot.rb", 1)
end
