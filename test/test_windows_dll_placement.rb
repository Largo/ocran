# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "pathname"
require_relative "../lib/ocran/direction"

# Windows packages carried the same DLL in up to three places (bin, the
# Ruby archdir and the devkit's msys64\ucrt64\bin): every DLL basename must
# be packed once, where the loader finds it for every extension. The
# decision is pure path logic, so it is tested on any platform.
class TestWindowsDllPlacement < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @prefix = Pathname(@dir) / "Ruby40-x64"
    @bindir = @prefix / "bin"
    @builtin = @bindir / "ruby_builtin_dlls"
    @archdir = @prefix / "lib/ruby/4.0.0/x64-mingw-ucrt"
    @msys = @prefix / "msys64/ucrt64/bin"
    [@builtin, @archdir, @msys].each(&:mkpath)
    %w[libwinpthread-1.dll libgmp-10.dll ruby_builtin_dlls.manifest].each { |f| (@builtin / f).write("") }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def place(candidates, builtin_dir: @builtin)
    Ocran::Direction.windows_dll_placement(candidates, exec_prefix: @prefix, bindir: @bindir,
                                           builtin_dir: builtin_dir, arch_dirs: [@archdir])
                    .map { |source, target, _| [source.relative_path_from(@prefix).to_s, target.to_s] }
  end

  def test_rubyinstaller_duplicates_are_packed_once_into_bin
    candidates = [
      [@msys / "libcrypto-3-x64.dll", "detected"],
      [@archdir / "libcrypto-3-x64.dll", "detected"],
      [@msys / "libffi-8.dll", "detected"],
      [@msys / "libwinpthread-1.dll", "detected"],
      [@archdir / "libcrypto-3-x64.dll", "companion"],
      [@archdir / "libssl-3-x64.dll", "companion"],
      [@archdir / "libyaml-0-2.dll", "companion"],
      [@archdir / "libwinpthread-1.dll", "companion"],
      [@msys / "zlib1.dll", "detected"],
      [@archdir / "zlib1.dll", "companion"],
    ]

    assert_equal [
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libcrypto-3-x64.dll", "bin/libcrypto-3-x64.dll"],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libssl-3-x64.dll", "bin/libssl-3-x64.dll"],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libyaml-0-2.dll", "bin/libyaml-0-2.dll"],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/zlib1.dll", "bin/zlib1.dll"],
      ["msys64/ucrt64/bin/libffi-8.dll", "bin/libffi-8.dll"],
    ], place(candidates)
  end

  def test_builtin_dlls_are_not_packed_again
    candidates = [
      [@builtin / "libgmp-10.dll", "detected"],
      [@msys / "libgmp-10.dll", "detected"],
      [@archdir / "libwinpthread-1.dll", "companion"],
    ]
    assert_empty place(candidates)
  end

  def test_without_ruby_builtin_dlls_the_dll_goes_into_bin
    assert_equal [["msys64/ucrt64/bin/libwinpthread-1.dll", "bin/libwinpthread-1.dll"]],
                 place([[@msys / "libwinpthread-1.dll", "detected"]], builtin_dir: nil)
  end

  def test_dll_in_bindir_stays_and_wins_over_other_copies
    candidates = [
      [@msys / "libffi-8.dll", "detected"],
      [@bindir / "libffi-8.dll", "imported"],
      [@bindir / "libffi-8.dll", "detected"],
    ]
    assert_equal [["bin/libffi-8.dll", "bin/libffi-8.dll"]], place(candidates)
  end

  def test_basenames_are_compared_case_insensitively
    candidates = [
      [@archdir / "ZLIB1.dll", "companion"],
      [@msys / "zlib1.dll", "detected"],
    ]
    assert_equal [["lib/ruby/4.0.0/x64-mingw-ucrt/ZLIB1.dll", "bin/ZLIB1.dll"]], place(candidates)
  end

  def test_gem_dll_also_keeps_its_original_location
    gem_dll = @prefix / "lib/ruby/gems/4.0.0/gems/tiny_tds-3.0.0/ports/bin/libsybdb-5.dll"
    assert_equal [
      ["lib/ruby/gems/4.0.0/gems/tiny_tds-3.0.0/ports/bin/libsybdb-5.dll", "bin/libsybdb-5.dll"],
      ["lib/ruby/gems/4.0.0/gems/tiny_tds-3.0.0/ports/bin/libsybdb-5.dll",
       "lib/ruby/gems/4.0.0/gems/tiny_tds-3.0.0/ports/bin/libsybdb-5.dll"],
    ], place([[gem_dll, "detected"]])
  end

  def test_dll_outside_the_prefix_goes_into_bin_after_ruby_tree_copies
    outside = Pathname(@dir) / "freetds/bin/libssl-3-x64.dll"
    candidates = [
      [outside, "detected"],
      [@archdir / "libssl-3-x64.dll", "companion"],
      [Pathname(@dir) / "freetds/bin/libsybdb-5.dll", "detected"],
    ]
    assert_equal [
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libssl-3-x64.dll", "bin/libssl-3-x64.dll"],
      ["../freetds/bin/libsybdb-5.dll", "bin/libsybdb-5.dll"],
    ], place(candidates)
  end
end
