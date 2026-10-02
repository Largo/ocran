# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/dir_builder"
require_relative "../lib/ocran/zip_writer"

# Unit tests for Ocran::DirBuilder.create_zip (--output-zip).
class TestDirBuilder < Minitest::Test
  S_IFMT = 0o170000
  S_IFLNK = 0o120000

  # Member name => UNIX st_mode of every entry in the archive at +path+.
  def zip_modes(path)
    File.open(path, "rb") do |io|
      eocd = Ocran::ZipWriter.read_eocd(io, path)
      central = Ocran::ZipWriter.read_central_directory(io, eocd)
      modes = {}
      pos = 0
      while central.byteslice(pos, 4) == Ocran::ZipWriter::CENTRAL_SIGNATURE
        name_length, extra_length, comment_length, _, _, external =
          central.byteslice(pos, 46).unpack("x28vvvvvV")
        modes[central.byteslice(pos + 46, name_length)] = external >> 16
        pos += 46 + name_length + extra_length + comment_length
      end
      modes
    end
  end

  def setup
    skip "the zip command is used on POSIX build hosts only" if Gem.win_platform?
    skip "zip command not installed" unless system("command -v zip > /dev/null 2>&1")
  end

  # Rebuilding onto an existing archive used to merge the old entries into
  # the new one.
  def test_existing_archive_is_replaced
    Dir.mktmpdir do |tmp|
      zip = File.join(tmp, "app.zip")
      src = File.join(tmp, "src")
      Dir.mkdir(src)
      File.write(File.join(src, "old.rb"), "old")
      Ocran::DirBuilder.create_zip(zip, src)

      File.delete(File.join(src, "old.rb"))
      File.write(File.join(src, "new.rb"), "new")
      Ocran::DirBuilder.create_zip(zip, src)

      assert_equal ["new.rb"], zip_modes(zip).keys
    end
  end

  # The libruby.so aliases are symlinks; followed, the library was stored
  # once per alias.
  def test_symlinks_are_stored_as_links
    Dir.mktmpdir do |tmp|
      zip = File.join(tmp, "app.zip")
      src = File.join(tmp, "src")
      Dir.mkdir(src)
      File.write(File.join(src, "libruby.so.4.0"), "library")
      File.symlink("libruby.so.4.0", File.join(src, "libruby.so"))
      Ocran::DirBuilder.create_zip(zip, src)

      modes = zip_modes(zip)
      assert_equal S_IFLNK, modes.fetch("libruby.so") & S_IFMT
      refute_equal S_IFLNK, modes.fetch("libruby.so.4.0") & S_IFMT
    end
  end
end
