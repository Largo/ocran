# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/zip_writer"

# Unit tests for Ocran::ZipWriter.append on archives made up in memory.
class TestZipWriter < Minitest::Test
  # An executable part followed by an empty ZIP archive, as in an APE.
  def archive(prefix)
    prefix.b + ["PK\x05\x06".b, 0, 0, 0, 0, 0, prefix.bytesize, 0].pack("a4vvvvVVv")
  end

  def with_archive(bytes)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ruby.com")
      File.binwrite(path, bytes)
      yield path
    end
  end

  def entry(name, data = "x")
    Ocran::ZipWriter::Entry.new(name: name, data: data)
  end

  # The ZIP64 check used to look for the locator signature anywhere in the
  # last 64 KiB, so the bytes merely occurring in the executable part (or
  # in a file name) refused the archive.
  def test_locator_bytes_elsewhere_are_not_zip64
    with_archive(archive("MZ" + "PK\x06\x07" + ("\0" * 64))) do |path|
      assert_operator Ocran::ZipWriter.append(path, [entry("main.rb")]), :>, 0
    end
  end

  # The limits of the format were checked only after the archive had been
  # cut open and the new entries written, which left the file broken.
  def test_too_many_entries_are_refused_before_writing
    bytes = archive("MZ")
    with_archive(bytes) do |path|
      entries = Array.new(Ocran::ZipWriter::MAX_ENTRIES + 1) { |i| entry("f#{i}", "") }
      error = assert_raises(RuntimeError) { Ocran::ZipWriter.append(path, entries) }
      assert_match(/too many ZIP entries/, error.message)
      assert_equal bytes, File.binread(path)
    end
  end

  def test_oversized_archive_is_refused_before_writing
    skip "needs a sparse file" if Gem.win_platform?

    bytes = archive("MZ")
    with_archive(bytes) do |path|
      big = File.join(File.dirname(path), "big")
      File.open(big, "wb") { |f| f.truncate(Ocran::ZipWriter::MAX_OFFSET + 1) }
      big_entry = Ocran::ZipWriter::Entry.new(name: "big", source: big)
      error = assert_raises(RuntimeError) { Ocran::ZipWriter.append(path, [big_entry]) }
      assert_match(/exceed 4 GiB/, error.message)
      assert_equal bytes, File.binread(path)
    end
  end

  def test_zip64_locator_before_the_record_is_refused
    locator = ["PK\x06\x07".b, 0, 0, 1].pack("a4VQ<V")
    with_archive(archive("MZ" + ("\0" * 64) + locator)) do |path|
      error = assert_raises(RuntimeError) { Ocran::ZipWriter.append(path, [entry("main.rb")]) }
      assert_match(/ZIP64/, error.message)
    end
  end
end
