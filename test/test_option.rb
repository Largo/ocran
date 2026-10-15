# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/ocran/option"
require_relative "../lib/ocran/stub_builder"

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

  def test_static_runtime_produces_an_exe_on_any_host
    Dir.mkdir("rt")
    option = parse("app.rb", "--static-runtime", "rt")
    assert option.static_runtime?
    assert_equal File.expand_path("rt"), option.static_runtime.to_s
    assert_equal File.expand_path("app.exe"), option.output_executable.to_s
  end

  def test_static_runtime_output_name_follows_the_runtime_os
    Dir.mkdir("rt")
    File.write("rt/runtime.json", '{"format": 1, "os": "linux"}')
    assert_equal File.expand_path("app"), parse("app.rb", "--static-runtime", "rt").output_executable.to_s
  end

  def test_static_runtime_rejects_other_outputs_and_stub_only_options
    Dir.mkdir("rt")
    assert_rejected(/--output-dir cannot be used with --static-runtime/, "app.rb", "--static-runtime", "rt", "--output-dir", "out")
    assert_rejected(/--output-zip cannot be used with --static-runtime/, "app.rb", "--static-runtime", "rt", "--output-zip", "o.zip")
    assert_rejected(/--debug-extract cannot be used with --static-runtime/, "app.rb", "--static-runtime", "rt", "--debug-extract")
    assert_rejected(/is not a directory/, "app.rb", "--static-runtime", "missing")
  end

  def test_windows_option_follows_the_static_runtime_os
    Dir.mkdir("rt")
    File.write("rt/runtime.json", '{"format": 1, "os": "windows"}')
    assert parse("app.rb", "--static-runtime", "rt", "--windows").windowed?
    refute parse("app.rb", "--static-runtime", "rt").windowed?
    File.write("app.rbw", "")
    assert parse("app.rbw", "--static-runtime", "rt").windowed?
    refute parse("app.rbw", "--static-runtime", "rt", "--console").windowed?

    File.write("rt/runtime.json", '{"format": 1, "os": "linux"}')
    refute parse("app.rbw", "--static-runtime", "rt").windowed?
    # Left for the builder to reject: --windows means nothing on Linux.
    assert parse("app.rb", "--static-runtime", "rt", "--windows").windowed?
  end

  def test_static_runtime_is_rejected_with_roundhouse
    Dir.mkdir("rt")
    Dir.mkdir("railsapp")
    assert_rejected(/--static-runtime cannot be used with --roundhouse/, "railsapp", "--roundhouse", "--static-runtime", "rt")
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

  def test_no_dep_run_warns_about_what_is_not_detected
    assert_empty parse("app.rb").warnings
    assert_empty parse("app.rb", "--no-dep-run", "--add-all-core").warnings
    assert_empty parse("app.rb", "--no-dep-run", "--add-all-core", "--gemfile", "Gemfile", "--gem-full").warnings

    assert_match(/--add-all-core/, parse("app.rb", "--no-dep-run").warnings.join)
    warnings = parse("app.rb", "--no-dep-run", "--add-all-core", "--gemfile", "Gemfile").warnings
    assert_match(/--gem-all or --gem-full/, warnings.join)
  end

  def test_missing_stub_says_how_to_build_it
    error = assert_raises(RuntimeError) { parse("app.rb").check_prebuilt_stub(File.expand_path("stub")) }
    assert_match(/launcher stub .*stub has not been built/, error.message)
    assert_match(/make(\.mswin)? .*install/, error.message)
    refute_match(/--no-wrapper-exe/, error.message)

    error = assert_raises(RuntimeError) do
      parse("app.rb", "--output-dir", "out").check_prebuilt_stub(File.expand_path("stub"))
    end
    assert_match(/--no-wrapper-exe/, error.message)
  end

  def test_existing_stub_passes_the_check
    File.write("stub", "")
    assert_nil parse("app.rb").check_prebuilt_stub(File.expand_path("stub"))
  end

  def test_prebuilt_stub_only_where_one_is_copied
    stub_dir = Ocran::Option::STUB_DIR
    # Kept in step with where StubBuilder copies the stub from.
    assert_equal stub_dir, File.dirname(Ocran::StubBuilder::STUB_PATH)
    assert_equal stub_dir, File.dirname(parse("app.rb").prebuilt_stub)
    assert_equal stub_dir, File.dirname(parse("app.rb", "--output-dir", "out").prebuilt_stub)
    assert_nil parse("app.rb", "--output-dir", "out", "--no-wrapper-exe").prebuilt_stub
    assert_nil parse("app.rb", "--output-zip", "o.zip", "--no-wrapper-exe").prebuilt_stub
    assert_nil parse("app.rb", "--spinel").prebuilt_stub
    Dir.mkdir("rt")
    assert_nil parse("app.rb", "--static-runtime", "rt").prebuilt_stub
  end
end
