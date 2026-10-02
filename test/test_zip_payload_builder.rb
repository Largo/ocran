# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/zip_payload_builder"

# Unit tests for the main.rb that Ocran::ZipPayloadBuilder generates
# (--cosmo-ruby ZIP packaging). An empty ZIP archive stands in for the
# cosmopolitan Ruby, so no interpreter is needed.
class TestZipPayloadBuilder < Minitest::Test
  EMPTY_ZIP = ("PK\x05\x06".b + ("\0" * 18)).freeze

  def bootstrap(**options)
    Dir.mktmpdir do |dir|
      ruby = File.join(dir, "ruby.com")
      File.binwrite(ruby, EMPTY_ZIP)
      builder = Ocran::ZipPayloadBuilder.new(File.join(dir, "app.com"), cosmo_ruby: ruby, **options) do |b|
        b.exec("bin/ruby.com", "src/app.rb")
      end
      builder.send(:bootstrap_source)
    end
  end

  CHDIR_TO_EXE_DIR = "Dir.chdir(File.dirname(executable))"

  # --chdir-exe-dir was accepted in this mode but did nothing.
  def test_chdir_exe_dir_changes_into_the_executable_directory
    assert_includes bootstrap(chdir_exe_dir: true), CHDIR_TO_EXE_DIR
  end

  def test_chdir_first_changes_into_the_executable_directory
    assert_includes bootstrap(chdir_before: true), CHDIR_TO_EXE_DIR
  end

  def test_no_chdir_by_default
    refute_includes bootstrap, "Dir.chdir"
  end
end
