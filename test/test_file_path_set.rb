# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/ocran/file_path_set"

# Unit tests for Ocran::FilePathSet and the path normalization it shares
# with Ocran::RefinePathname.
class TestFilePathSet < Minitest::Test
  using Ocran::RefinePathname

  ROOT = File.expand_path("/ocran-test-root")

  def src(relative) = File.join(ROOT, relative)

  # Runs the block with RefinePathname.path_key normalizing as it does on
  # Windows (case-insensitive, either separator), whatever the host is.
  def as_on_windows
    key = Ocran::RefinePathname.method(:path_key)
    Ocran::RefinePathname.singleton_class.send(:define_method, :path_key) do |path|
      path.to_s.tr("\\", "/").downcase
    end
    yield
  ensure
    Ocran::RefinePathname.singleton_class.send(:define_method, :path_key, key)
  end

  def test_path_key_is_the_path_itself_on_posix
    skip "POSIX only" if File::ALT_SEPARATOR
    assert_equal "Lib/Foo.rb", Pathname("Lib/Foo.rb").path_key
  end

  def test_refinements_do_not_reach_hash_and_uniq
    # The reason FilePathSet keys on path_key: C code calls the unrefined
    # Pathname#hash/eql?, so these collections would not deduplicate.
    as_on_windows do
      a, b = Pathname("C:/App/Foo.rb"), Pathname("c:\\app\\foo.rb")
      assert a.eql?(b), "refined eql? sees one file"
      assert_equal 2, [a, b].uniq.size
      assert_equal 1, [a, b].uniq { |path| path.path_key }.size
    end
  end

  def test_same_target_in_another_spelling_is_one_entry_on_windows
    as_on_windows do
      set = Ocran::FilePathSet.new
      assert set.add?(src("App/Foo.rb"), "src/Foo.rb")
      assert_nil set.add?(src("app/foo.rb"), "SRC/foo.rb")
      assert_equal [[Pathname(src("App/Foo.rb")), Pathname("src/Foo.rb")]], set.to_a

      error = assert_raises(RuntimeError) { set.add?(src("other.rb"), "src/FOO.rb") }
      assert_match(/Conflicting sources/, error.message)
    end
  end

  def test_targets_differing_in_case_stay_apart_on_posix
    skip "POSIX only" if File::FNM_SYSCASE.nonzero?

    set = Ocran::FilePathSet.new
    assert set.add?(src("Foo.rb"), "src/Foo.rb")
    assert set.add?(src("foo.rb"), "src/foo.rb")
    assert_nil set.add?(src("foo.rb"), "src/foo.rb")
    assert_equal 2, set.to_a.size
  end
end
