# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "pathname"
require_relative "../lib/ocran/direction"

# --add-all-core walks the Ruby library directories. An entry that is not
# a readable file - Debian's rdoc fonts are links into a package that may
# not be installed - used to abort the build with ENOENT.
class TestCoreLibraryFiles < Minitest::Test
  def test_entries_that_are_not_readable_files_are_skipped
    skip "creating symlinks needs privileges on Windows" if Gem.win_platform?
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      (root / "sub").mkpath
      (root / "a.rb").write("")
      (root / "sub/b.rb").write("")
      File.symlink("a.rb", root / "link.rb")
      File.symlink("missing.ttf", root / "sub/broken.ttf")

      files, skipped = Ocran::Direction.core_library_files(root)

      assert_equal %w[a.rb link.rb sub/b.rb], files.map { _1.relative_path_from(root).to_s }.sort
      assert_equal %w[sub/broken.ttf], skipped.map { _1.relative_path_from(root).to_s }
    end
  end
end
