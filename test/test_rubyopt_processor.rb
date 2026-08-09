# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/ocran/rubyopt_processor"

# Unit tests for Ocran::RubyoptProcessor. These are pure Ruby and run on
# any platform (no Windows or packing environment required).
class TestRubyoptProcessor < Minitest::Test
  # A platform-valid absolute directory to build fixture paths from.
  # File.expand_path makes it drive-aware on Windows ("C:/ocran-test-root")
  # and plain absolute on POSIX ("/ocran-test-root"), so
  # File.absolute_path? recognizes the fixture paths on both platforms.
  ABS_ROOT = File.expand_path("/ocran-test-root")

  # Absolute fixture path under ABS_ROOT.
  def abs(relative)
    File.join(ABS_ROOT, relative)
  end

  # Translates +rubyopt+ using +map+ (absolute build path => packed path).
  def translate(rubyopt, map = {})
    Ocran::RubyoptProcessor.new(rubyopt).translate { |path| map[path] }
  end

  def test_empty_rubyopt
    result = translate("")
    assert_equal "", result.rubyopt
    assert_empty result.load_paths
    assert_empty result.requires
    assert_empty result.dropped
    refute result.translated?
  end

  def test_non_path_options_pass_through
    result = translate("-w -W:deprecated --enable=frozen-string-literal")
    assert_equal "-w -W:deprecated --enable=frozen-string-literal", result.rubyopt
    refute result.translated?
  end

  def test_relative_require_is_kept
    result = translate("-rtime -w")
    assert_equal "-rtime -w", result.rubyopt
    assert_empty result.requires
  end

  def test_detached_relative_require_is_kept
    result = translate("-r time")
    assert_equal "-rtime", result.rubyopt
  end

  def test_absolute_require_is_translated
    feature = abs("build/gems/foo-1.0/lib/foo")
    map = { feature => "gems/foo-1.0/lib/foo" }
    result = translate("-r#{feature} -w", map)
    assert_equal "-w", result.rubyopt
    assert_equal ["gems/foo-1.0/lib/foo"], result.requires
    assert result.translated?
  end

  def test_detached_absolute_require_is_translated
    feature = abs("build/lib/foo")
    map = { feature => "src/lib/foo" }
    result = translate("-r #{feature}", map)
    assert_equal "", result.rubyopt
    assert_equal ["src/lib/foo"], result.requires
  end

  def test_unmapped_absolute_require_is_dropped_with_notice
    feature = abs("nonexistent/foo")
    result = translate("-r#{feature} -rtime")
    assert_equal "-rtime", result.rubyopt
    assert_empty result.requires
    assert_equal ["-r#{feature}"], result.dropped
  end

  def test_bundler_setup_is_stripped_silently
    result = translate("-r#{abs("build/gems/bundler-2.5.0/lib/bundler/setup")} -w")
    assert_equal "-w", result.rubyopt
    assert_empty result.requires
    assert_empty result.dropped
  end

  def test_relative_bundler_setup_with_prefix_is_stripped
    result = translate("-rfoo/bundler/setup")
    assert_equal "", result.rubyopt
    assert_empty result.dropped
  end

  def test_plain_relative_bundler_setup_is_kept
    # Matches the historical behavior: only paths with a directory
    # component before bundler/setup are stripped.
    result = translate("-rbundler/setup")
    assert_equal "-rbundler/setup", result.rubyopt
  end

  def test_absolute_load_path_is_translated
    dir = abs("build/app/lib")
    map = { dir => "src/lib" }
    result = translate("-I#{dir}", map)
    assert_equal "", result.rubyopt
    assert_equal ["src/lib"], result.load_paths
  end

  def test_detached_load_path_is_translated
    dir = abs("build/app/lib")
    map = { dir => "src/lib" }
    result = translate("-I #{dir}", map)
    assert_equal "", result.rubyopt
    assert_equal ["src/lib"], result.load_paths
  end

  def test_relative_load_path_is_kept
    result = translate("-Ilib")
    assert_equal "-Ilib", result.rubyopt
    assert_empty result.load_paths
  end

  def test_multiple_dirs_in_one_load_path_option
    sep = File::PATH_SEPARATOR
    dir = abs("build/app/lib")
    map = { dir => "src/lib" }
    result = translate("-I#{dir}#{sep}vendor", map)
    assert_equal "-Ivendor", result.rubyopt
    assert_equal ["src/lib"], result.load_paths
  end

  def test_multiple_absolute_dirs_in_one_load_path_option
    sep = File::PATH_SEPARATOR
    dir_a = abs("build/a/lib")
    dir_b = abs("build/b/lib")
    map = { dir_a => "src/a", dir_b => "src/b" }
    result = translate("-I#{dir_a}#{sep}#{dir_b}", map)
    assert_equal "", result.rubyopt
    assert_equal ["src/a", "src/b"], result.load_paths
  end

  def test_unmapped_absolute_load_path_is_dropped_with_notice
    dir = abs("nonexistent/lib")
    result = translate("-I#{dir} -w")
    assert_equal "-w", result.rubyopt
    assert_empty result.load_paths
    assert_equal ["-I#{dir}"], result.dropped
  end

  def test_order_of_translated_entries_is_preserved
    map = {
      abs("a/lib") => "src/a",
      abs("b/lib") => "src/b",
      abs("a/setup") => "src/a_setup",
      abs("b/setup") => "src/b_setup"
    }
    rubyopt = "-I#{abs("a/lib")} -I#{abs("b/lib")} -r#{abs("a/setup")} -r#{abs("b/setup")}"
    result = translate(rubyopt, map)
    assert_equal ["src/a", "src/b"], result.load_paths
    assert_equal ["src/a_setup", "src/b_setup"], result.requires
  end

  def test_trailing_option_without_argument_is_ignored
    assert_equal "", translate("-r").rubyopt
    assert_equal "", translate("-I").rubyopt
  end

  def test_exact_rubyopt_string_preserved_when_nothing_translates
    # Mirrors test_rubyopt_manual in test_ocra.rb, which asserts the baked
    # RUBYOPT equals the string given to --rubyopt.
    result = translate("-rbundler --verbose")
    assert_equal "-rbundler --verbose", result.rubyopt
  end
end
