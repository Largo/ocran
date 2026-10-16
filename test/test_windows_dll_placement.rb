# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "pathname"
require_relative "../lib/ocran/direction"

# Windows packages carried the same DLL in up to three places (bin, the
# Ruby archdir and the devkit's msys64\ucrt64\bin). A DLL must be packed
# where the loader looks for it - beside its extension when the extension's
# SxS assembly lists it, in bin otherwise - and nowhere else. The decision
# is path and manifest logic, so it is tested on any platform.
class TestWindowsDllPlacement < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @prefix = Pathname(@dir) / "Ruby40-x64"
    @bindir = @prefix / "bin"
    @builtin = @bindir / "ruby_builtin_dlls"
    @archdir = @prefix / "lib/ruby/4.0.0/x64-mingw-ucrt"
    @msys = @prefix / "msys64/ucrt64/bin"
    @fiddle = @prefix / "lib/ruby/gems/4.0.0/extensions/x64-mingw-ucrt/4.0.0/fiddle-1.1.8"
    [@builtin, @archdir, @msys, @fiddle].each(&:mkpath)
    %w[libwinpthread-1.dll libgmp-10.dll].each { |f| (@builtin / f).write("") }
    assembly(@builtin, "ruby_builtin_dlls", "libgmp-10.dll", "libwinpthread-1.dll")
    # RubyInstaller 4.0's layout
    assembly(@archdir, "openssl.so-assembly", "libcrypto-3-x64.dll", "libssl-3-x64.dll")
    assembly(@archdir, "psych.so-assembly", "libyaml-0-2.dll")
    assembly(@archdir, "zlib.so-assembly", "zlib1.dll")
    assembly(@archdir, "date_core.so-assembly", "libwinpthread-1.dll")
    assembly(@fiddle, "fiddle.so-assembly", "libffi-8.dll")
  end

  def assembly(dir, name, *files)
    (dir / "#{name}.manifest").write(<<~XML)
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        <assemblyIdentity type="win32" name="#{name}" version="1.0.0.0"></assemblyIdentity>

        #{files.map { |f| %(<file name="#{f}"/>) }.join}
      </assembly>
    XML
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def place(candidates, builtin_dir: @builtin)
    Ocran::Direction.windows_dll_placement(candidates, exec_prefix: @prefix, bindir: @bindir,
                                           builtin_dir: builtin_dir, arch_dirs: [@archdir])
                    .map { |source, target, _| [source.relative_path_from(@prefix).to_s, target.to_s] }
  end

  def test_rubyinstaller_layout
    candidates = [
      [@archdir / "libcrypto-3-x64.dll", "detected"],
      [@archdir / "libssl-3-x64.dll", "detected"],
      [@msys / "ZLIB1.dll", "detected"],
      [@archdir / "libyaml-0-2.dll", "detected"],
      [@archdir / "zlib1.dll", "detected"],
      [@fiddle / "libffi-8.dll", "detected"],
      [@archdir / "libcrypto-3-x64.dll", "companion"],
      [@archdir / "libssl-3-x64.dll", "companion"],
      [@archdir / "libwinpthread-1.dll", "companion"],
      [@archdir / "libyaml-0-2.dll", "companion"],
      [@archdir / "zlib1.dll", "companion"],
      [@fiddle / "libffi-8.dll", "companion"],
      [@msys / "libwinpthread-1.dll", "detected"],
    ]

    # Assembly files stay beside their extension, and only there; ZLIB1.dll,
    # which OpenSSL loads by name from the devkit, goes into bin once.
    assert_equal [
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libcrypto-3-x64.dll", "lib/ruby/4.0.0/x64-mingw-ucrt/libcrypto-3-x64.dll"],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libssl-3-x64.dll", "lib/ruby/4.0.0/x64-mingw-ucrt/libssl-3-x64.dll"],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libyaml-0-2.dll", "lib/ruby/4.0.0/x64-mingw-ucrt/libyaml-0-2.dll"],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/zlib1.dll", "lib/ruby/4.0.0/x64-mingw-ucrt/zlib1.dll"],
      [@fiddle.relative_path_from(@prefix).join("libffi-8.dll").to_s, @fiddle.relative_path_from(@prefix).join("libffi-8.dll").to_s],
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libwinpthread-1.dll", "lib/ruby/4.0.0/x64-mingw-ucrt/libwinpthread-1.dll"],
      ["msys64/ucrt64/bin/ZLIB1.dll", "bin/ZLIB1.dll"],
    ], place(candidates)
  end

  def test_dll_without_an_assembly_goes_into_bin_once
    (@archdir / "date_core.so-assembly.manifest").delete
    candidates = [
      [@msys / "libffi-8.dll", "detected"],
      [@archdir / "libfoo-1.dll", "companion"],
      [@msys / "libfoo-1.dll", "detected"],
    ]
    assert_equal [
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libfoo-1.dll", "bin/libfoo-1.dll"],
      ["msys64/ucrt64/bin/libffi-8.dll", "bin/libffi-8.dll"],
    ], place(candidates)
  end

  def test_builtin_dlls_are_not_packed_again
    (@archdir / "date_core.so-assembly.manifest").delete
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

  def test_bindir_outside_exec_prefix_bin_maps_to_bin
    bindir = @prefix / "usr/bin"
    candidates = [[bindir / "libgmp-10.dll", "imported"], [@msys / "libgmp-10.dll", "detected"]]
    placement = Ocran::Direction.windows_dll_placement(candidates, exec_prefix: @prefix, bindir: bindir)
    assert_equal [["usr/bin/libgmp-10.dll", "bin/libgmp-10.dll"]],
                 placement.map { |source, target, _| [source.relative_path_from(@prefix).to_s, target.to_s] }
  end

  def test_basenames_are_compared_case_insensitively
    candidates = [
      [@archdir / "ZLIB1.dll", "companion"],
      [@msys / "zlib1.dll", "detected"],
      [@prefix / "lib/ruby/site_ruby/libbar.dll", "detected"],
      [@msys / "LIBBAR.dll", "detected"],
    ]
    assert_equal [
      ["lib/ruby/4.0.0/x64-mingw-ucrt/ZLIB1.dll", "lib/ruby/4.0.0/x64-mingw-ucrt/ZLIB1.dll"],
      ["lib/ruby/site_ruby/libbar.dll", "bin/libbar.dll"],
      ["lib/ruby/site_ruby/libbar.dll", "lib/ruby/site_ruby/libbar.dll"],
      ["msys64/ucrt64/bin/zlib1.dll", "bin/zlib1.dll"],
    ], place(candidates)
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
    candidates = [
      [Pathname(@dir) / "freetds/bin/libiconv-2.dll", "detected"],
      [@archdir / "libiconv-2.dll", "companion"],
      [Pathname(@dir) / "freetds/bin/libsybdb-5.dll", "detected"],
    ]
    assert_equal [
      ["lib/ruby/4.0.0/x64-mingw-ucrt/libiconv-2.dll", "bin/libiconv-2.dll"],
      ["../freetds/bin/libsybdb-5.dll", "bin/libsybdb-5.dll"],
    ], place(candidates)
  end
end
