# frozen_string_literal: true
require "zlib"

module Ocran
  # Minimal ZIP archive appender, used to inject an application into the
  # ZIP store of a cosmopolitan Ruby APE (see ZipPayloadBuilder).
  #
  # Why not shell out to the `zip` command: OCRAN packages applications on
  # Windows build hosts too, where `zip` generally does not exist, and even
  # on POSIX it is not guaranteed to be installed. Why not rubyzip: OCRAN
  # has exactly one runtime dependency (fiddle) and adding a gem just to
  # append a few hundred stored/deflated entries is not worth it. Zlib is
  # part of the standard library, and the format below is the 1989-era
  # subset (no ZIP64, no encryption, no data descriptors) that
  # Cosmopolitan's zipos reads.
  #
  # Appending, specifically: an APE already contains a ZIP archive (the
  # interpreter's own standard library lives in it), and the existing
  # entries must keep working. The layout of a ZIP file is
  #
  #   [local header + data]*  [central directory]  [end of central directory]
  #
  # and the central directory records absolute offsets of the local
  # headers. So the append is: cut the file at the start of the central
  # directory, write the new local headers there, write the ORIGINAL
  # central directory bytes unchanged (every offset it holds is still
  # valid, because nothing before it moved), then the central directory
  # records for the new entries, then a fresh end-of-central-directory
  # record. This is what the `zip` command does when it appends to an
  # archive with a non-ZIP prefix, and it leaves the executable part of the
  # APE - which lives before all of this - byte-identical.
  module ZipWriter
    # End of central directory record: signature plus 18 bytes of fixed
    # fields; a trailing archive comment may follow.
    EOCD_SIGNATURE = "PK\x05\x06".b
    EOCD_SIZE = 22
    # A ZIP archive comment can be up to 0xffff bytes, so the record can
    # start at most that far from the end of the file.
    MAX_EOCD_SEARCH = 0xffff + EOCD_SIZE

    # Markers of the ZIP64 format extensions. OCRAN never writes them; an
    # input archive that uses them is rejected rather than corrupted.
    ZIP64_EOCD_LOCATOR_SIGNATURE = "PK\x06\x07".b

    CENTRAL_SIGNATURE = "PK\x01\x02".b
    LOCAL_SIGNATURE = "PK\x03\x04".b

    # "Made by" field: UNIX (3) in the high byte so the external file
    # attributes below are read as UNIX permission bits, ZIP spec 2.0 in
    # the low byte.
    VERSION_MADE_BY = (3 << 8) | 20
    # Version needed to extract: 2.0 is what DEFLATE requires.
    VERSION_NEEDED = 20
    # General purpose bit 11: file name is UTF-8.
    FLAG_UTF8 = 0x0800

    METHOD_STORED = 0
    METHOD_DEFLATED = 8

    # MS-DOS directory attribute, set in the low byte of the external file
    # attributes for directory entries.
    MSDOS_DIR_ATTRIBUTE = 0x10

    # UNIX st_mode file type bits, stored in the high word of the external
    # file attributes together with the permission bits. They are NOT
    # optional: Cosmopolitan's zipos reports the external attributes as
    # st_mode, and a member without S_IFREG is not a regular file - Ruby's
    # own require/load refuse to open it (they check S_ISREG), and a
    # directory without S_IFDIR cannot be traversed, so Dir.glob comes back
    # empty even though File.read on the exact path works. This mismatch is
    # what makes an otherwise valid archive unusable inside an APE.
    S_IFREG = 0o100000
    S_IFDIR = 0o040000
    DEFAULT_FILE_MODE = 0o644
    DEFAULT_DIRECTORY_MODE = 0o755

    # An archive member to add. +name+ is the archive-relative path (with
    # forward slashes, no leading slash); a name ending in "/" is a
    # directory entry with no content. +source+ is a path to read the
    # content from, +data+ is the content itself; exactly one of them is
    # given for a file entry.
    Entry = Struct.new(:name, :source, :data, :mode, :mtime, keyword_init: true) do
      def directory? = name.end_with?("/")

      def content
        return "".b if directory?

        (data || File.binread(source)).b
      end
    end

    module_function

    # Appends the given entries to the ZIP archive at the end of +path+,
    # in place. Returns the number of bytes the file grew by.
    #
    # Raises when the file has no readable central directory, when it uses
    # ZIP64, or when an entry would shadow a name the archive already
    # contains (a duplicate name is not a format error, but for the APE it
    # would mean an application file silently overriding part of the
    # interpreter's own standard library).
    def append(path, entries)
      entries = entries.reject(&:nil?)
      return 0 if entries.empty?

      File.open(path, "r+b") do |io|
        eocd = read_eocd(io, path)
        central = read_central_directory(io, eocd)
        existing = central_directory_names(central)

        entries.each do |entry|
          if existing.include?(entry.name)
            raise "cannot add #{entry.name} to #{path}: the archive already contains an entry with that name"
          end
        end

        entries = with_parent_directories(entries, existing)

        before = io.size
        io.truncate(eocd[:cd_offset])
        io.seek(eocd[:cd_offset])

        records = entries.map { |entry| write_local(io, entry) }

        cd_offset = io.pos
        io.write(central)
        records.each { |record| io.write(central_record(record)) }
        cd_size = io.pos - cd_offset

        io.write(end_of_central_directory(eocd[:total_entries] + records.size, cd_size, cd_offset))
        io.size - before
      end
    end

    # Returns the entries with an explicit directory entry inserted before
    # every member for each parent directory that neither the archive nor
    # the entry list already provides. A ZIP archive does not require them,
    # but zipos builds its directory listings from the members it can see,
    # so without them Dir.glob and Dir.entries do not find the packed tree.
    def with_parent_directories(entries, existing)
      seen = existing.dup
      entries.each { |entry| seen[entry.name] = true }

      entries.flat_map { |entry|
        parents = entry.name.split("/")[0...-1].inject([]) { |acc, part|
          acc << "#{acc.last}#{part}/"
        }
        missing = parents.reject { |name| seen[name] }
        missing.each { |name| seen[name] = true }
        missing.map { |name| Entry.new(name: name) } << entry
      }
    end

    # Locates and decodes the end-of-central-directory record. The record
    # is searched for from the end of the file because a ZIP archive is
    # identified by its tail, which is what allows one to be appended to an
    # executable in the first place.
    def read_eocd(io, path)
      size = io.size
      tail_size = [size, MAX_EOCD_SEARCH].min
      io.seek(size - tail_size)
      tail = io.read(tail_size)

      offset = tail.rindex(EOCD_SIGNATURE)
      unless offset
        raise "#{path} does not end in a ZIP archive (no end-of-central-directory record found); " \
              "it cannot be a cosmopolitan APE with an embedded ZIP store"
      end

      if tail.rindex(ZIP64_EOCD_LOCATOR_SIGNATURE)
        raise "#{path} uses the ZIP64 format extensions, which OCRAN cannot append to"
      end

      _signature, _disk, _cd_disk, _disk_entries, total_entries, cd_size, cd_offset, comment_length =
        tail.byteslice(offset, EOCD_SIZE).unpack("a4vvvvVVv")

      eocd_start = size - tail_size + offset
      unless eocd_start + EOCD_SIZE + comment_length == size
        raise "#{path} has trailing data after its ZIP archive; OCRAN cannot append to it"
      end

      { cd_offset: cd_offset, cd_size: cd_size, total_entries: total_entries }
    end

    def read_central_directory(io, eocd)
      io.seek(eocd[:cd_offset])
      return "".b if eocd[:cd_size].zero?

      central = io.read(eocd[:cd_size]).to_s.b
      unless central.bytesize == eocd[:cd_size] && central.start_with?(CENTRAL_SIGNATURE)
        raise "the ZIP central directory is truncated or malformed"
      end
      central
    end

    # Names of the entries already in the archive, so an application file
    # cannot silently shadow one of them.
    def central_directory_names(central)
      names = {}
      pos = 0
      while central.byteslice(pos, 4) == CENTRAL_SIGNATURE
        name_length, extra_length, comment_length = central.byteslice(pos, 46).unpack("x28vvv")
        names[central.byteslice(pos + 46, name_length)] = true
        pos += 46 + name_length + extra_length + comment_length
      end
      names
    end

    # Writes one local file header plus its data at the current position
    # and returns the bookkeeping the central directory record needs.
    def write_local(io, entry)
      content = entry.content
      crc = Zlib.crc32(content)
      compressed, method = compress(content)

      name = entry.name.b
      flags = name.ascii_only? ? 0 : FLAG_UTF8
      dos_time, dos_date = dos_timestamp(entry.mtime || Time.now)
      offset = io.pos

      io.write([LOCAL_SIGNATURE, VERSION_NEEDED, flags, method, dos_time, dos_date,
                crc, compressed.bytesize, content.bytesize, name.bytesize, 0]
                 .pack("a4vvvvvVVVvv"))
      io.write(name)
      io.write(compressed)

      { name: name, flags: flags, method: method, dos_time: dos_time, dos_date: dos_date,
        crc: crc, compressed_size: compressed.bytesize, size: content.bytesize,
        offset: offset, mode: st_mode(entry), directory: entry.directory? }
    end

    # The UNIX st_mode an extractor (and zipos) should report for the
    # entry: the permission bits plus the file type.
    def st_mode(entry)
      if entry.directory?
        S_IFDIR | (entry.mode || DEFAULT_DIRECTORY_MODE)
      else
        S_IFREG | (entry.mode || DEFAULT_FILE_MODE)
      end
    end

    # DEFLATE unless it does not pay off. Raw deflate streams (negative
    # window bits) are what the ZIP format stores - Zlib.deflate would add
    # a zlib header that no unzipper expects.
    def compress(content)
      return ["".b, METHOD_STORED] if content.empty?

      deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
      deflated = begin
        deflater.deflate(content, Zlib::FINISH)
      ensure
        deflater.close
      end
      deflated.bytesize < content.bytesize ? [deflated, METHOD_DEFLATED] : [content, METHOD_STORED]
    end

    def central_record(record)
      external = (record[:mode] << 16) | (record[:directory] ? MSDOS_DIR_ATTRIBUTE : 0)

      [CENTRAL_SIGNATURE, VERSION_MADE_BY, VERSION_NEEDED, record[:flags], record[:method],
       record[:dos_time], record[:dos_date], record[:crc], record[:compressed_size],
       record[:size], record[:name].bytesize, 0, 0, 0, 0, external, record[:offset]]
        .pack("a4vvvvvvVVVvvvvvVV") + record[:name]
    end

    def end_of_central_directory(total_entries, cd_size, cd_offset)
      if total_entries > 0xffff
        raise "too many ZIP entries (#{total_entries}); OCRAN does not write ZIP64 archives"
      end
      if cd_offset + cd_size > 0xffffffff
        raise "the packaged archive would exceed 4 GiB; OCRAN does not write ZIP64 archives"
      end

      [EOCD_SIGNATURE, 0, 0, total_entries, total_entries, cd_size, cd_offset, 0]
        .pack("a4vvvvVVv")
    end

    # MS-DOS packed time and date. The format has two-second resolution and
    # starts in 1980, so earlier timestamps are clamped.
    def dos_timestamp(time)
      time = time.getlocal
      year = [time.year, 1980].max
      [(time.hour << 11) | (time.min << 5) | (time.sec / 2),
       ((year - 1980) << 9) | (time.month << 5) | time.day]
    end
  end
end
