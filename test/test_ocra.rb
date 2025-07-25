require "minitest/autorun"

require "tmpdir"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "pathname"

begin
  require "rubygems"
  gem 'win32-api', '>=1.2.0'
  require "win32/api"
  $have_win32_api = true
rescue LoadError
  $have_win32_api = false
end

include FileUtils

class TestOcran < Minitest::Test

  # Default arguments for invoking OCRAN when running tests.
  DefaultArgs = %w[--no-lzma --verbose].tap do |ary|
    ary << "--quiet" unless ENV["OCRAN_VERBOSE_TEST"]
  end.freeze

  # Name of the tested ocran script.
  TESTED_OCRAN = ENV['TESTED_OCRAN'] || 'ocran'

  # Root of OCRAN.
  OcranRoot = File.expand_path(File.join(File.dirname(__FILE__), '..'))

  # Path to test fixtures.
  FixturePath = File.expand_path(File.join(File.dirname(__FILE__), 'fixtures'))

  # Create a pristine environment to test built executables. Files are
  # copied and the PATH environment is set to the minimal. Yields to
  # the block, then cleans up.
  def pristine_env(*files)
    # Use Bundler.with_original_env to temporarily revert any environment modifications made by Bundler,
    # especially clearing the RUBYOPT environment variable set by `bundle exec`. This ensures that
    # the testing environment is clean and unaffected by Bundler's settings, providing a pristine
    # environment to accurately test the built executables.
    Bundler.with_original_env do
      with_tmpdir files do
        with_env "PATH" => ENV["SystemRoot"] + ";" + ENV["SystemRoot"] + "\\SYSTEM32" do
          yield
        end
      end
    end
  end

  def system(*args)
    puts args.join(" ") if ENV["OCRAN_VERBOSE_TEST"]
    Kernel.system(*args)
  end

  attr_reader :ocran

  def initialize(*args)
    super(*args)
    @ocran = File.expand_path(File.join(File.dirname(__FILE__), '..', 'exe', TESTED_OCRAN))
    ENV['RUBYOPT'] = ""
  end

  # Sets up an directory with a copy of a fixture and yields to the
  # block, then cleans up everything. A fixture here is a hierachy of
  # files located in test/fixtures.
  def with_fixture(name, target_path = nil)
    path = File.join(FixturePath, name)
    with_tmpdir([], target_path) do
      cp_r path, '.'
      cd name do
        yield
      end
    end
  end

  # Sets up temporary environment variables and yields to the
  # block. When the block exits, the environment variables are set
  # back to their original values.
  def with_env(hash)
    old = ENV.except(hash.keys)
    ENV.update(hash)
    begin
      yield
    ensure
      ENV.update(old)
    end
  end

  def with_tmpdir(files = [], path = nil)
    tempdirname = path || Dir.mktmpdir(".ocrantest-")
    mkdir_p tempdirname
    begin
      cp files, tempdirname
      FileUtils.cd tempdirname do
        yield
      end
    ensure
      FileUtils.rm_rf tempdirname
    end
  end

  # Should be able to build executable when specifying absolute path
  # to the script from somewhere else.
  def test_abspath
    with_fixture "helloworld" do
      script_path = File.expand_path("helloworld.rb")
      with_tmpdir do
        assert system("ruby", ocran, script_path, "--rubyopt", "--debug", *DefaultArgs)
        assert File.exist?("helloworld.exe")
        pristine_env "helloworld.exe" do
          assert system("helloworld.exe")
        end
      end
    end
  end
end
