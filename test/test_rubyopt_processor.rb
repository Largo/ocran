# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/ocran/rubyopt_processor"

# Unit tests for Ocran::RubyoptProcessor. These are pure Ruby and run on
# any platform (no Windows or packing environment required).
class TestRubyoptProcessor < Minitest::Test
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
    map = { "/build/gems/foo-1.0/lib/foo" => "gems/foo-1.0/lib/foo" }
    result = translate("-r/build/gems/foo-1.0/lib/foo -w", map)
    assert_equal "-w", result.rubyopt
    assert_equal ["gems/foo-1.0/lib/foo"], result.requires
    assert result.translated?
  end

  def test_detached_absolute_require_is_translated
    map = { "/build/lib/foo" => "src/lib/foo" }
    result = translate("-r /build/lib/foo", map)
    assert_equal "", result.rubyopt
    assert_equal ["src/lib/foo"], result.requires
  end

  def test_unmapped_absolute_require_is_dropped_with_notice
    result = translate("-r/nonexistent/foo -rtime")
    assert_equal "-rtime", result.rubyopt
    assert_empty result.requires
    assert_equal ["-r/nonexistent/foo"], result.dropped
  end

  def test_bundler_setup_is_stripped_silently
    result = translate("-r/build/gems/bundler-2.5.0/lib/bundler/setup -w")
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
    map = { "/build/app/lib" => "src/lib" }
    result = translate("-I/build/app/lib", map)
    assert_equal "", result.rubyopt
    assert_equal ["src/lib"], result.load_paths
  end

  def test_detached_load_path_is_translated
    map = { "/build/app/lib" => "src/lib" }
    result = translate("-I /build/app/lib", map)
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
    map = { "/build/app/lib" => "src/lib" }
    result = translate("-I/build/app/lib#{sep}vendor", map)
    assert_equal "-Ivendor", result.rubyopt
    assert_equal ["src/lib"], result.load_paths
  end

  def test_unmapped_absolute_load_path_is_dropped_with_notice
    result = translate("-I/nonexistent/lib -w")
    assert_equal "-w", result.rubyopt
    assert_empty result.load_paths
    assert_equal ["-I/nonexistent/lib"], result.dropped
  end

  def test_order_of_translated_entries_is_preserved
    map = {
      "/a/lib" => "src/a",
      "/b/lib" => "src/b",
      "/a/setup" => "src/a_setup",
      "/b/setup" => "src/b_setup"
    }
    result = translate("-I/a/lib -I/b/lib -r/a/setup -r/b/setup", map)
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
