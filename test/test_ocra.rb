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

  def relative_or_absolute_path(from_path, to_path)
    begin
      # Attempt to generate a relative path
      Pathname.new(to_path).relative_path_from(Pathname.new(from_path)).to_s
    rescue ArgumentError
      # If a relative path cannot be computed, return the absolute path
      Pathname.new(to_path).realpath.to_s
    end
  end

  def each_path_combo(*files)
    # In same directory as first file
    basedir = Pathname.new(files[0]).realpath.parent
    args = files.map{|p| relative_or_absolute_path(basedir, p) }
    cd basedir do
      yield(*args)
    end

    # In parent directory of first file
    basedir = basedir.parent
    args = files.map{|p| relative_or_absolute_path(basedir, p) }
    cd basedir do
      yield(*args)
    end

    # In a completely different directory
    args = files.map{|p|Pathname.new(p).realpath.to_s}
    with_tmpdir do
      yield(*args)
    end
  end

  # Hello world test. Test that we can build and run executables.
  def test_helloworld
    with_fixture 'helloworld' do
      each_path_combo "helloworld.rb" do |script|
        assert system("ruby", ocran, script, *DefaultArgs)
        assert File.exist?("helloworld.exe")
        pristine_env "helloworld.exe" do
          assert system("helloworld.exe")
        end
      end
    end
  end

  # Should be able to build executables with LZMA compression
  def test_lzma
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", "--quiet", "--lzma")
      assert File.exist?("helloworld.exe")
      pristine_env "helloworld.exe" do
        assert system("helloworld.exe")
      end
    end
  end

  # Test that executables can writing a file to the current working
  # directory.
  def test_writefile
    with_fixture 'writefile' do
      assert system("ruby", ocran, "writefile.rb", *DefaultArgs)
      assert File.exist?("output.txt") # Make sure ocran ran the script during build
      pristine_env "writefile.exe" do
        assert File.exist?("writefile.exe")
        assert system("writefile.exe")
        assert File.exist?("output.txt")
        assert_equal "output", File.read("output.txt")
      end
    end
  end

  # With --no-dep-run, ocran should not run script during build
  def test_nodeprun
    with_fixture 'writefile' do
      assert system("ruby", ocran, "writefile.rb", *(DefaultArgs + ["--no-dep-run"]))
      assert !File.exist?("output.txt")
      pristine_env "writefile.exe" do
        assert File.exist?("writefile.exe")
        assert system("writefile.exe")
        assert File.exist?("output.txt")
        assert_equal "output", File.read("output.txt")
      end
    end
  end

  # With dep run disabled but including all core libs, should be able
  # to use ruby standard libraries (i.e. cgi)
  def test_rubycoreincl
    with_fixture 'rubycoreincl' do
      assert system("ruby", ocran, "rubycoreincl.rb", *(DefaultArgs + ["--no-dep-run", "--add-all-core"]))
      pristine_env "rubycoreincl.exe" do
        assert File.exist?("rubycoreincl.exe")
        assert system("rubycoreincl.exe")
        assert File.exist?("output.txt")
        assert_equal "3 &lt; 5", File.read("output.txt")
      end
    end
  end

  # With dep run disabled but including corelibs and using a Bundler Gemfile, specified gems should
  # be automatically included and usable in packaged app
  def test_gemfile
    with_fixture 'bundlerusage' do
      assert system("ruby", ocran, "bundlerusage.rb", "Gemfile", *(DefaultArgs + ["--no-dep-run", "--add-all-core", "--gemfile", "Gemfile", "--gem-all"]))
      pristine_env "bundlerusage.exe" do
        assert system("bundlerusage.exe")
      end
    end
  end

  # With --debug-extract option, exe should unpack to local directory and leave it in place
  def test_debug_extract
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--debug-extract"]))
      pristine_env "helloworld.exe" do
        assert_equal 0, Dir["ocr*"].size
        assert system("helloworld.exe")
        assert_equal 1, Dir["ocr*"].size
      end
    end
  end

  # Test that the --output option allows us to specify a different exe name
  def test_output_option
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output", "goodbyeworld.exe"]))
      assert !File.exist?("helloworld.exe")
      assert File.exist?("goodbyeworld.exe")
    end
  end

  # Test that we can specify a directory to be recursively included
  def test_directory_on_cmd_line
    with_fixture 'subdir' do
      assert system("ruby", ocran, "subdir.rb", "a", *DefaultArgs)
      pristine_env "subdir.exe" do
        assert system("subdir.exe")
      end
    end
  end

  # Test that scripts can exit with a specific exit status code.
  def test_exitstatus
    with_fixture 'exitstatus' do
      assert system("ruby", ocran, "exitstatus.rb", *DefaultArgs)
      pristine_env "exitstatus.exe" do
        system("exitstatus.exe")
        assert_equal 167, $?.exitstatus
      end
    end
  end

  # Test that arguments are passed correctly to scripts.
  def test_arguments1
    with_fixture 'arguments' do
      assert system("ruby", ocran, "arguments.rb", *DefaultArgs)
      assert File.exist?("arguments.exe")
      pristine_env "arguments.exe" do
        system("arguments.exe foo \"bar baz \\\"quote\\\"\"")
        assert_equal 5, $?.exitstatus
      end
    end
  end

  # Test that arguments are passed correctly to scripts (specified at
  # compile time).
  def test_arguments2
    with_fixture 'arguments' do
      args = DefaultArgs + ["--", "foo", "bar baz \"quote\"" ]
      assert system("ruby", ocran, "arguments.rb", *args)
      assert File.exist?("arguments.exe")
      pristine_env "arguments.exe" do
        system("arguments.exe")
        assert_equal 5, $?.exitstatus
      end
    end
  end

  # Test that arguments are passed correctly to scripts (specified at
  # compile time).
  def test_arguments3
    with_fixture 'arguments' do
      args = DefaultArgs + ["--", "foo"]
      assert system("ruby", ocran, "arguments.rb", *args)
      assert File.exist?("arguments.exe")
      pristine_env "arguments.exe" do
        system("arguments.exe \"bar baz \\\"quote\\\"\"")
        assert_equal 5, $?.exitstatus
      end
    end
  end

  # Test that arguments are passed correctly at build time.
  def test_buildarg
    with_fixture "buildarg" do
      args = DefaultArgs + [ "--", "--some-option" ]
      assert system("ruby", ocran, "buildarg.rb", *args)
      assert File.exist?("buildarg.exe")
      pristine_env "buildarg.exe" do
        assert system("buildarg.exe")
      end
    end
  end

  # Test that the standard output from a script can be redirected to a
  # file.
  def test_stdout_redir
    with_fixture 'stdoutredir' do
      assert system("ruby", ocran, "stdoutredir.rb", *DefaultArgs)
      assert File.exist?("stdoutredir.exe")
      pristine_env "stdoutredir.exe" do
        system("stdoutredir.exe > output.txt")
        assert File.exist?("output.txt")
        assert_equal "Hello, World!\n", File.read("output.txt")
      end
    end
  end

  # Test that the standard input to a script can be redirected from a
  # file.
  def test_stdin_redir
    with_fixture 'stdinredir' do
      assert system("ruby", ocran, "stdinredir.rb", *DefaultArgs)
      assert File.exist?("stdinredir.exe")
      # Kernel.system("ruby -e \"system 'stdinredir.exe<input.txt';p $?\"")
      pristine_env "stdinredir.exe", "input.txt" do
        system("stdinredir.exe < input.txt")
      end
      assert_equal 104, $?.exitstatus
    end
  end

  # Test that executables can include dll's using the --dll
  # option. Sets PATH=. while running the executable so that it can't
  # find the DLL from the Ruby installation.
  def test_gdbmdll
    args = DefaultArgs.dup
    if not $have_win32_api
      gdbmdll = Dir.glob(File.join(RbConfig::CONFIG['bindir'], 'gdbm*.dll'))[0]
      return if gdbmdll.nil?
      args.push '--dll', File.basename(gdbmdll)
    end

    with_fixture 'gdbmdll' do
      assert system("ruby", ocran, "gdbmdll.rb", *args)
      with_env 'PATH' => '.' do
        pristine_env "gdbmdll.exe" do
          system("gdbmdll.exe")
          assert_equal 104, $?.exitstatus
        end
      end
    end
  end

  # Test that scripts can require a file relative to the location of
  # the script and that such files are correctly added to the
  # executable.
  def test_relative_require
    with_fixture 'relativerequire' do
      assert system("ruby", ocran, "relativerequire.rb", *DefaultArgs)
      assert File.exist?("relativerequire.exe")
      pristine_env "relativerequire.exe" do
        system("relativerequire.exe")
        assert_equal 160, $?.exitstatus
      end
    end
  end

  # Test that autoloaded files which are not actually loaded while
  # running the script through Ocran are included in the resulting
  # executable.
  def test_autoload
    with_fixture 'autoload' do
      assert system("ruby", ocran, "autoload.rb", *DefaultArgs)
      assert File.exist?("autoload.exe")
      pristine_env "autoload.exe" do
        assert system("autoload.exe")
      end
    end
  end

  # Test that autoload statement which point to non-existing files are
  # ignored by Ocran
  def test_autoload_missing
    with_fixture 'autoloadmissing' do
      require "open3"
      _o, e, _s = Open3.capture3("ruby", ocran, "autoloadmissing.rb", *DefaultArgs)
      assert_match %r{\AWARNING: Foo::Bar loading failed:}, e
      assert File.exist?("autoloadmissing.exe")
      pristine_env "autoloadmissing.exe" do
        assert system("autoloadmissing.exe")
      end
    end
  end

  # Test that Ocran picks up autoload statement nested in modules.
  def test_autoload_nested
    with_fixture 'autoloadnested' do
      assert system("ruby", ocran, "autoloadnested.rb", *DefaultArgs)
      assert File.exist?("autoloadnested.exe")
      pristine_env "autoloadnested.exe" do
        assert system("autoloadnested.exe")
      end
    end
  end

  # Should find features via relative require paths, after script
  # changes to the right directory (Only valid for Ruby < 1.9.2).
  def test_relative_require_chdir_path
    with_fixture "relloadpath" do
      each_path_combo "bin/chdir1.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        assert File.exist?('chdir1.exe')
        pristine_env "chdir1.exe" do
          assert system('chdir1.exe')
        end
      end
    end
  end

  # Should find features via relative require paths prefixed with
  # './', after script changes to the right directory.
  def test_relative_require_chdir_dotpath
    with_fixture "relloadpath" do
      each_path_combo "bin/chdir2.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        assert File.exist?('chdir2.exe')
        pristine_env "chdir2.exe" do
          assert system('chdir2.exe')
        end
      end
    end
  end

  # Should pick up files from relative load paths specified using the
  # -I option when invoking Ocran, and invoking from same directory as
  # script.
  def test_relative_require_i
    with_fixture 'relloadpath' do
      each_path_combo "bin/external.rb", "lib", "bin/sub" do |script, *loadpaths|
        assert system('ruby', '-I', loadpaths[0], '-I', loadpaths[1], ocran, script, *DefaultArgs)
        assert File.exist?('external.exe')
        pristine_env "external.exe" do
          assert system('external.exe')
        end
      end
    end
  end

  # Should pick up files from relative load path specified using the
  # RUBYLIB environment variable.
  def test_relative_require_rubylib
    with_fixture 'relloadpath' do
      each_path_combo "bin/external.rb", "lib", "bin/sub" do |script, *loadpaths|
        with_env 'RUBYLIB' => loadpaths.join(';') do
          assert system('ruby', ocran, script, *DefaultArgs)
        end
        assert File.exist?('external.exe')
        pristine_env "external.exe" do
          assert system('external.exe')
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # dirname of script.
  def test_loadpath_mangling_dirname
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath0.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        assert File.exist?('loadpath0.exe')
        pristine_env "loadpath0.exe" do
          assert system('loadpath0.exe')
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # relative paths, and invoking from same directory.
  def test_loadpath_mangling_path
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath1.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        assert File.exist?('loadpath1.exe')
        pristine_env "loadpath1.exe" do
          assert system('loadpath1.exe')
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # relative paths with './'-prefix
  def test_loadpath_mangling_dotpath
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath2.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        assert File.exist?('loadpath2.exe')
        pristine_env "loadpath2.exe" do
          assert system('loadpath2.exe')
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # absolute paths.
  def test_loadpath_mangling_abspath
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath3.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        assert File.exist?('loadpath3.exe')
        pristine_env "loadpath3.exe" do
          assert system('loadpath3.exe')
        end
      end
    end
  end

  # Test that ocran.rb accepts --version and outputs the version number.
  def test_version
    assert_match(/^Ocran \d+(\.\d)+(.(:?[a-z]+)?\d+)?\n$/, `ruby \"#{ocran}\" --version`)
  end

  # Test that ocran.rb accepts --icon.
  def test_icon
    with_fixture 'helloworld' do
      icofile = File.join(OcranRoot, 'src', 'vit-ruby.ico')
      assert system("ruby", ocran, '--icon', icofile, "helloworld.rb", *DefaultArgs)
      assert File.exist?("helloworld.exe")
      pristine_env "helloworld.exe" do
        assert system("helloworld.exe")
      end
    end
  end

  # Test that additional non-script files can be added to the
  # executable and used by the script.
  def test_resource
    with_fixture 'resource' do
      assert system("ruby", ocran, "resource.rb", "resource.txt", "res/resource.txt", *DefaultArgs)
      assert File.exist?("resource.exe")
      pristine_env "resource.exe" do
        assert system("resource.exe")
      end
    end
  end

  # Test that when exceptions are thrown, no executable will be built.
  def test_exception
    with_fixture 'exception' do
      system("ruby \"#{ocran}\" exception.rb #{DefaultArgs.join(' ')} 2>NUL")
      assert $?.exitstatus != 0
      assert !File.exist?("exception.exe")
    end
  end

  # Test that the RUBYOPT environment variable is preserved when --rubyopt is not passed
  def test_rubyopt
    with_fixture 'environment' do
      with_env "RUBYOPT" => "-rtime" do
        assert system("ruby", ocran, "environment.rb", *DefaultArgs)
        pristine_env "environment.exe" do
          assert system("environment.exe")
          env = Marshal.load(File.open("environment", "rb") { |f| f.read })
          # Verify that the specified RUBYOPT is included in the execution environment.
          # NOTE: In Ruby 3.2 and later, Bundler may add additional options to RUBYOPT.
          assert_includes env['RUBYOPT'], "-rtime"
        end
      end
    end
  end

  # Test that the RUBYOPT environment variable can be set manually with --rubyopt
  def test_rubyopt_manual
    specified_rubyopt = "-rbundler --verbose"
    # Starting with Ruby 2.6, Bundler is now the default GEM. To do this, use
    # the '--add-all-core' option to include bnundler in the package.
    test_args = DefaultArgs + ["--add-all-core", "--rubyopt", "#{specified_rubyopt}"]
    with_fixture 'environment' do
      with_env "RUBYOPT" => "-rtime" do
        assert system("ruby", ocran, "environment.rb", *test_args)
        pristine_env "environment.exe" do
          assert system("environment.exe")
          env = Marshal.load(File.open("environment", "rb") { |f| f.read })
          assert_equal specified_rubyopt, env['RUBYOPT']
        end
      end
    end
  end

  def test_exit
    with_fixture 'exit' do
      assert system("ruby", ocran, "exit.rb", *DefaultArgs)
      pristine_env "exit.exe" do
        assert File.exist?("exit.exe")
        assert system("exit.exe")
      end
    end
  end

  def test_ocran_executable_env
    with_fixture 'environment' do
      assert system("ruby", ocran, "environment.rb", *DefaultArgs)
      pristine_env "environment.exe" do
        assert system("environment.exe")
        env = Marshal.load(File.open("environment", "rb") { |f| f.read })
        expected_path = File.expand_path("environment.exe").tr('/','\\')
        assert_equal expected_path, env['OCRAN_EXECUTABLE']
      end
    end
  end

  def test_hierarchy
    with_fixture 'hierarchy' do
      assert system("ruby", ocran, "hierarchy.rb", "assets/**/*", *DefaultArgs)
      pristine_env "hierarchy.exe" do
        assert system("hierarchy.exe")
      end
    end
  end

  def test_temp_with_space
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      tempdir = File.expand_path("temporary directory")
      mkdir_p tempdir
      pristine_env "helloworld.exe" do
        with_env "TMP" => tempdir.tr('/','\\') do
          assert system("helloworld.exe")
        end
      end
    end
  end

  # Should be able to build executable when specifying absolute path
  # to the script from somewhere else.
  def test_abspath
    with_fixture "helloworld" do
      script_path = File.expand_path("helloworld.rb")
      with_tmpdir do
        assert system("ruby", ocran, script_path, *DefaultArgs)
        assert File.exist?("helloworld.exe")
        pristine_env "helloworld.exe" do
          assert system("helloworld.exe")
        end
      end
    end
  end

  def test_abspath_outside
    with_fixture "helloworld" do
      mkdir "build"
      cd "build" do
        assert system("ruby", ocran, File.expand_path("../helloworld.rb"), *DefaultArgs)
        assert File.exist?("helloworld.exe")
        pristine_env "helloworld.exe" do
          assert system("helloworld.exe")
        end
      end
    end
  end

  def test_relpath
    with_fixture "helloworld" do
      assert system("ruby", ocran, "./helloworld.rb", *DefaultArgs)
      assert File.exist?("helloworld.exe")
      pristine_env "helloworld.exe" do
        assert system("helloworld.exe")
      end
    end
  end

  def test_relpath_outside
    with_fixture "helloworld" do
      mkdir "build"
      cd "build" do
        assert system("ruby", ocran, "../helloworld.rb", *DefaultArgs)
        assert File.exist?("helloworld.exe")
        pristine_env "helloworld.exe" do
          assert system("helloworld.exe")
        end
      end
    end
  end

  # Should accept hierachical source code layout
  def test_srcroot
    with_fixture "srcroot" do
      assert system("ruby", ocran, "bin/srcroot.rb", "share/data.txt", *DefaultArgs)
      assert File.exist?("srcroot.exe")
      pristine_env "srcroot.exe" do
        exe = File.expand_path("srcroot.exe")
        cd ENV["SystemRoot"] do
          assert system(exe)
        end
      end
    end
  end

  # Should be able to build executables when script changes directory.
  def test_chdir
    with_fixture "chdir" do
      assert system("ruby", ocran, "chdir.rb", *DefaultArgs)
      assert File.exist?("chdir.exe")
      pristine_env "chdir.exe" do
        exe = File.expand_path("chdir.exe")
        cd ENV["SystemRoot"] do
          assert system(exe)
        end
      end
    end
  end

  # Test that the --chdir-first option changes directory before exe starts script
  def test_chdir_first
    with_fixture 'writefile' do
      # Control test; make sure the writefile script works as expected under default options
      assert system("ruby", ocran, "writefile.rb", *(DefaultArgs))
      pristine_env "writefile.exe" do
        assert !File.exist?("output.txt")
        assert system("writefile.exe")
        assert File.exist?("output.txt")
      end

      assert system("ruby", ocran, "writefile.rb", *(DefaultArgs + ["--chdir-first"]))
      pristine_env "writefile.exe" do
        assert !File.exist?("output.txt")
        assert system("writefile.exe")
        # If the script ran in its inst directory, then our working dir still shouldn't have any output.txt
        assert !File.exist?("output.txt")
      end
    end
  end

  # Would be nice if OCRAN could build from source located beneath the
  # Ruby installation too.
  def test_exec_prefix
    path = File.join(RbConfig::CONFIG["exec_prefix"], "ocrantempsrc")
    with_fixture "helloworld", path do
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      assert File.exist?("helloworld.exe")
      pristine_env "helloworld.exe" do
        assert system("helloworld.exe")
      end
    end
  end

  def test_explicit_in_exec_prefix
    return unless File.directory?(RbConfig::CONFIG["exec_prefix"] + "/include")
    path = File.join(RbConfig::CONFIG["exec_prefix"], "include", "**", "*.h")
    number_of_files = Dir[path].size
    assert number_of_files > 3
    with_fixture "check_includes" do
      assert system("ruby", ocran, "check_includes.rb", path, *DefaultArgs)
      assert File.exist?("check_includes.exe")
      pristine_env "check_includes.exe" do
        assert system("check_includes.exe", number_of_files.to_s)
      end
    end
  end

  # Hello world test. Test that we can build and run executables.
  def test_nonexistent_temp
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      assert File.exist?("helloworld.exe")
      pristine_env "helloworld.exe" do
        with_env "TEMP" => "c:\\thispathdoesnotexist12345", "TMP" => "c:\\thispathdoesnotexist12345" do
          assert File.exist?("helloworld.exe")
          system("helloworld.exe 2>NUL")
          assert File.exist?("helloworld.exe")
        end
      end
    end
  end

  # Should be able to build an installer using Inno Setup.
  def test_innosetup
    skip unless system("where ISCC >NUL 2>&1")
    with_fixture 'innosetup' do
      icon_file = File.join(OcranRoot, 'src', 'vit-ruby.ico')
      assert system("ruby", ocran, "innosetup.rb", '--icon', icon_file, "--quiet",
                    "--innosetup", "innosetup.iss", "--chdir-first", "--no-lzma")
      assert File.exist?("Output/innosetup.exe")
    end
  end

  # With --debug option
  def test_debug
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--debug"]))
      pristine_env "helloworld-debug.exe" do
        require 'open3'
        Open3.popen3("helloworld-debug.exe") do |_stdin, _stdout, stderr, wait_thr|
          # The Ocran stub outputs in debug mode to the standard output.
          assert_equal "DEBUG: Ocran stub running in debug mode\n", stderr.gets
          stderr.read # Ignore the output content after the first line
          assert wait_thr.value # exit status
        end
      end
    end
  end

  # Tests whether an OCRAN-built executable runs correctly from a directory
  # with multibyte (UTF-8) characters in its name.
  def test_multibyte_path_execution
    with_fixture 'helloworld' do
      exe_name = "helloworld.exe"
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      assert File.exist?(exe_name)

      multibyte_dir = "äあ💎"

      pristine_env exe_name do
        mkdir_p multibyte_dir
        cp exe_name, multibyte_dir
        Dir.chdir(multibyte_dir) do
          assert system(exe_name)
        end
      end
    end
  end

  # Tests building and running a Ruby script with multibyte (UTF-8) characters
  # in its filename. Skipped unless the console code page is UTF-8 (65001),
  # as ruby.exe misinterprets arguments under non-UTF-8 environments.
  def test_multibyte_script_filename
    cp = `chcp`.force_encoding(Encoding::BINARY)[/\d+/] || "unknown"
    unless cp == "65001"
      skip "Skipped: console code page must be UTF-8 (65001), got #{cp}"
    end

    with_fixture 'multibyte_script' do
      script = "äあ💎.rb"
      assert system("ruby", ocran, script, *DefaultArgs)
      exe_name = script.sub(/\.rb$/, '.exe')
      assert File.exist?(exe_name)
      pristine_env exe_name do
        assert system(exe_name)
      end
    end
  end

  # Tests if a multibyte-named resource file is correctly included and read
  # at runtime after being packaged by OCRAN.
  def test_multibyte_resource_file
    with_fixture 'multibyte_file' do
      assert system("ruby", ocran, "resource.rb", "äあ💎.txt", *DefaultArgs)
      assert File.exist?("resource.exe")
      pristine_env "resource.exe" do
        assert system("resource.exe")
      end
    end
  end

  # Tests that OCRAN can handle resource files stored in a directory
  # with multibyte (UTF-8) characters in its name.
  def test_multibyte_resource_dir
    with_fixture 'multibyte_dir' do
      assert system("ruby", ocran, "resource.rb", "äあ💎/äあ💎.txt", *DefaultArgs)
      assert File.exist?("resource.exe")
      pristine_env "resource.exe" do
        assert system("resource.exe")
      end
    end
  end
end
