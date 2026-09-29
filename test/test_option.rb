# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/option"

# Unit tests for command line validation in Ocran::Option#parse. Invalid
# and conflicting options must be rejected before the dependency run.
class TestOption < Minitest::Test
  def setup
    @saved_dir = Dir.pwd
    @tmp = Dir.mktmpdir
    Dir.chdir(@tmp)
    File.write("app.rb", "")
    File.write("app.iss", "")
    File.write("Gemfile", "")
  end

  def teardown
    Dir.chdir(@saved_dir)
    FileUtils.remove_entry(@tmp)
  end

  def parse(*args)
    Ocran::Option.new.tap { |option| option.parse(args) }
  end

  def assert_rejected(pattern, *args)
    error = assert_raises(RuntimeError) { parse(*args) }
    assert_match pattern, error.message
  end

  def test_innosetup_rejects_output_dir_and_zip
    inno = %w[--innosetup app.iss --no-lzma --chdir-first]
    assert_rejected(/--innosetup cannot be combined/, "app.rb", *inno, "--output-dir", "out")
    assert_rejected(/--innosetup cannot be combined/, "app.rb", *inno, "--output-zip", "out.zip")
  end

  def test_unknown_gem_group_is_rejected_at_parse_time
    assert_rejected(/Invalid gem content detection option --gem-foo/, "app.rb", "--gem-foo")
    assert_rejected(/Invalid gem content detection option --gem-fulll=x/, "app.rb", "--gem-fulll=x")
    # Only the file sets can be negated; --no-gem-full used to act as --gem-full.
    assert_rejected(/Invalid gem content detection option --no-gem-full/, "app.rb", "--no-gem-full")
  end

  def test_valid_gem_groups_are_accepted
    option = parse("app.rb", "--gem-full=rake,json", "--no-gem-extras", "--gem-spec")
    assert_equal [[nil, :full, %w[rake json]], ["no-", :extras, nil], [nil, :spec, nil]], option.gem_options
  end

  def test_windows_and_console_conflict
    assert_rejected(/--windows and --console cannot be used together/, "app.rb", "--windows", "--console")
  end

  def test_unknown_option_is_an_error
    assert_rejected(/Unknown option --outptu/, "app.rb", "--outptu", "x")
  end

  def test_options_without_their_argument_are_rejected
    %w[--output --output-dir --output-zip --bundle-id --dll --icon --rubyopt
       --cosmo --gemfile --innosetup].each do |name|
      assert_rejected(/\A#{name} requires an argument\z/, "app.rb", name)
    end
    assert_rejected(/--output requires an argument/, "app.rb", "--output", "")
  end

  def test_empty_rubyopt_is_accepted
    assert_equal "", parse("app.rb", "--rubyopt", "").rubyopt
  end
end
