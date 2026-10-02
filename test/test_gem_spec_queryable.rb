# frozen_string_literal: true
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/ocran/gem_spec_queryable"

# Unit tests for Ocran::GemSpecQueryable#find_gem_files. They use a gem
# directory made up in a temporary directory, so no installed gem is needed.
class TestGemSpecQueryable < Minitest::Test
  def with_gem
    Dir.mktmpdir do |dir|
      gem_dir = File.join(dir, "gems", "demo-1.0")
      %w[lib/demo.rb lib/demo/extra.rb data/table.txt README.md].each do |rel|
        path = File.join(gem_dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rel)
      end

      spec = Gem::Specification.new do |s|
        s.name = "demo"
        s.version = "1.0"
        # A listed file the installed gem does not have is skipped.
        s.files = %w[lib/demo.rb data/table.txt missing.rb]
      end
      spec.define_singleton_method(:gem_dir) { gem_dir }
      spec.extend(Ocran::GemSpecQueryable)
      yield spec, Pathname(gem_dir)
    end
  end

  # The gemspec lists files relative to the gem directory; returning them
  # relative made every --gem-spec build fail ("Don't know where to put
  # gemfile lib/demo.rb").
  def test_spec_files_are_absolute_paths_in_the_gem_directory
    with_gem do |spec, gem_dir|
      files = spec.find_gem_files([:spec], [])
      assert_equal [gem_dir / "data/table.txt", gem_dir / "lib/demo.rb"], files.sort
      assert files.all?(&:absolute?)
    end
  end

  def test_overlapping_file_sets_are_returned_once
    with_gem do |spec, gem_dir|
      loaded = [gem_dir / "lib/demo.rb"]
      files = spec.find_gem_files([:loaded, :scripts, :spec], loaded)
      assert_equal files.uniq, files
      assert_equal 1, files.count(gem_dir / "lib/demo.rb")
    end
  end
end
