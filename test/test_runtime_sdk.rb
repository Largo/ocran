# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../lib/ocran/runtime_sdk"

# Unit tests for Ocran::RuntimeSdk#link with a stand-in compiler that
# records its command lines, so they run without a Windows toolchain.
class TestRuntimeSdk < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @sdk = File.join(@dir, "sdk")
    @log = File.join(@dir, "commands.log")
    FileUtils.mkdir_p(File.join(@sdk, "exts"))
    # The stand-in "compiler" logs its arguments and creates whatever file
    # follows -o or -Fe, like a real one would.
    @cc = File.join(@dir, "x86_64-w64-mingw32ucrt-gcc")
    File.write(@cc, <<~SH)
      #!/bin/sh
      echo "$(basename "$0") $*" >> #{@log}
      prev=""
      for a in "$@"; do
        case "$a" in -Fe*) : > "${a#-Fe}";; esac
        [ "$prev" = "-o" ] && : > "$a"
        prev="$a"
      done
      exit 0
    SH
    File.chmod(0o755, @cc)
    FileUtils.cp(@cc, File.join(@dir, "x86_64-w64-mingw32ucrt-strip"))
    File.write(File.join(@sdk, "exts", "fiddle.line"), "fiddle Init_fiddle @SDK@/exts/fiddle.a -lffi,-lws2_32\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_sdk(toolchain, args)
    File.write(File.join(@sdk, "link.args"), args.join("\n") + "\n")
    File.write(File.join(@sdk, "sdk.json"), JSON.generate("toolchain" => toolchain))
    Ocran::RuntimeSdk.new(@sdk, arch: "x64-mingw-ucrt")
  end

  def commands = File.readlines(@log, chomp: true)

  def test_gcc_link_registers_every_extension_and_appends_extra_inputs
    skip "the stand-in compiler is a shell script" if Gem.win_platform?
    sdk = write_sdk("gcc", [@cc, "-static", "@SDK@/ocran_main.o", "@EXTRA@", "@SDK@/libruby-static.a", "-L@SDK@/deps/lib"])
    ext = Ocran::RuntimeSdk::Extension.new("bcrypt_ext", "Init_bcrypt_ext", "/tmp/bcrypt_ext.a", [])
    out = File.join(@dir, "app-runtime.exe")
    sdk.link([ext], out)

    compile, link, strip = commands
    assert_match(/-O2 -c .*ocran_exts\.c -o .*ocran_exts\.o\z/, compile)
    assert_includes link, "-static #{@sdk}/ocran_main.o "
    assert_match(%r{ocran_exts\.o #{@sdk}/exts/fiddle\.a -lffi -lws2_32 /tmp/bcrypt_ext\.a #{@sdk}/libruby-static\.a -L#{@sdk}/deps/lib -o #{out}\z}, link)
    assert_equal "x86_64-w64-mingw32ucrt-strip #{out}", strip
    assert File.file?(out)
  end

  # sdk.json names the SDK build host's strip; MSYS2's gcc (named with
  # OCRAN_RUNTIME_CC) comes with strip, not x86_64-w64-mingw32ucrt-strip.
  def test_strip_follows_a_compiler_named_with_ocran_runtime_cc
    skip "the stand-in compiler is a shell script" if Gem.win_platform?
    gcc = File.join(@dir, "gcc")
    FileUtils.cp(@cc, gcc)
    FileUtils.cp(@cc, File.join(@dir, "strip"))
    File.write(File.join(@sdk, "link.args"), [@cc, "@EXTRA@"].join("\n") + "\n")
    File.write(File.join(@sdk, "sdk.json"), JSON.generate("toolchain" => "gcc", "strip" => "x86_64-w64-mingw32ucrt-strip"))
    sdk = Ocran::RuntimeSdk.new(@sdk, arch: "x64-mingw-ucrt")
    out = File.join(@dir, "app-runtime.exe")
    with_env("OCRAN_RUNTIME_CC" => gcc) { sdk.link([], out) }
    assert_equal "strip #{out}", commands.last
  end

  def test_no_strip_when_the_sdk_says_so
    skip "the stand-in compiler is a shell script" if Gem.win_platform?
    File.write(File.join(@sdk, "link.args"), [@cc, "@EXTRA@"].join("\n") + "\n")
    File.write(File.join(@sdk, "sdk.json"), JSON.generate("toolchain" => "gcc", "strip" => nil))
    Ocran::RuntimeSdk.new(@sdk, arch: "arm64-darwin24").link([], File.join(@dir, "app"))
    refute commands.any? { _1.include?("strip") }
  end

  def with_env(vars)
    saved = vars.keys.to_h { [_1, ENV[_1]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_dll_libraries_are_linked_through_their_import_library
    skip "the stand-in compiler is a shell script" if Gem.win_platform?
    File.write(File.join(@sdk, "sdk.json"), JSON.generate(
      "toolchain" => "gcc", "libs" => ["-lsybdb", "-liconv", "-lws2_32"],
      "dlls" => { "sybdb" => { "dll" => "deps/bin/libsybdb-5.dll", "import" => "deps/lib/libsybdb.dll.a" } }))
    File.write(File.join(@sdk, "link.args"), [@cc, "@EXTRA@", "-L@SDK@/deps/lib"].join("\n") + "\n")
    sdk = Ocran::RuntimeSdk.new(@sdk, arch: "x64-mingw-ucrt")
    sdk.link([], File.join(@dir, "out.exe"), dlls: ["sybdb"])
    link = commands[1]
    assert_includes link, " #{@sdk}/deps/lib/libsybdb.dll.a -liconv -lws2_32 "
    refute_includes link, "-lsybdb"
    error = assert_raises(RuntimeError) { sdk.link([], File.join(@dir, "x.exe"), dlls: ["ssl"]) }
    assert_match(/No DLL build of ssl .*available: sybdb/, error.message)
  end

  def test_extension_registration_source
    sdk = write_sdk("gcc", [@cc, "@EXTRA@"])
    source = sdk.send(:exts_source, sdk.base_extensions +
                      [Ocran::RuntimeSdk::Extension.new("jaro_winkler/jaro_winkler_ext", "Init_jaro_winkler_ext", "x", [])])
    assert_includes source, 'ruby_init_ext("fiddle.so", Init_fiddle);'
    assert_includes source, 'ruby_init_ext("jaro_winkler/jaro_winkler_ext.so", Init_jaro_winkler_ext);'
    assert_includes source, "extern void Init_jaro_winkler_ext(void);"
  end

  def test_msvc_output_goes_where_link_args_put_it
    sdk = write_sdk("msvc", ["cl", "-nologo", "@EXTRA@", "-Fe@OUTPUT@", "-link", "-libpath:@SDK@/deps/lib"])
    assert sdk.msvc?
    assert_equal "cl", sdk.cc
  end

  def test_extension_lines_reject_unsafe_names
    assert_raises(RuntimeError) { Ocran::RuntimeSdk::Extension.parse("x;rm Init_x a.a", @sdk) }
    assert_raises(RuntimeError) { Ocran::RuntimeSdk::Extension.parse("x Init_x() a.a", @sdk) }
    ext = Ocran::RuntimeSdk::Extension.parse("racc/cparse Init_cparse @SDK@/exts/racc_cparse.a ", @sdk)
    assert_equal File.join(@sdk, "exts/racc_cparse.a"), ext.archive
    assert_empty ext.libs
  end
end
