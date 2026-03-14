require "minitest/autorun"

require "tmpdir"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "pathname"
require "bundler"
require_relative "fake_code_signer"

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

  # Helper to get platform-specific executable name
  def exe_name(base)
    Gem.win_platform? ? "#{base}.exe" : base
  end

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
        if Gem.win_platform?
          with_env "PATH" => ENV["SystemRoot"] + ";" + ENV["SystemRoot"] + "\\SYSTEM32" do
            yield
          end
        else
          # On POSIX systems, use minimal PATH with current directory for testing executables
          with_env "PATH" => ".:/usr/local/bin:/usr/bin:/bin" do
            yield
          end
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

    # In parent directory of first file (skip on POSIX systems: output name can collide
    # with the script's parent directory since there is no .exe extension)
    if Gem.win_platform?
      basedir = basedir.parent
      args = files.map{|p| relative_or_absolute_path(basedir, p) }
      cd basedir do
        yield(*args)
      end
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
        assert File.exist?(exe_name("helloworld"))
        pristine_env exe_name("helloworld") do
          assert system(exe_name("helloworld"))
        end
      end
    end
  end

  # Should be able to build executables with LZMA compression
  def test_lzma
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", "--quiet", "--lzma")
      assert File.exist?(exe_name("helloworld"))
      pristine_env exe_name("helloworld") do
        assert system(exe_name("helloworld"))
      end
    end
  end

  # Test that executables can writing a file to the current working
  # directory.
  def test_writefile
    with_fixture 'writefile' do
      assert system("ruby", ocran, "writefile.rb", *DefaultArgs)
      assert File.exist?("output.txt") # Make sure ocran ran the script during build
      exe = exe_name("writefile")
      pristine_env exe do
        assert File.exist?(exe)
        assert system(exe)
        assert File.exist?("output.txt")
        assert_equal "output", File.read("output.txt")
      end
    end
  end

  # With --no-dep-run, ocran should not run script during build
  def test_nodeprun
    with_fixture 'writefile' do
      assert system("ruby", ocran, "writefile.rb", *(DefaultArgs + ["--no-dep-run"]))
      refute File.exist?("output.txt")
      exe = exe_name("writefile")
      pristine_env exe do
        assert File.exist?(exe)
        assert system(exe)
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
      exe = exe_name("rubycoreincl")
      pristine_env exe do
        assert File.exist?(exe)
        assert system(exe)
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
      exe = exe_name("bundlerusage")
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # With --debug-extract option, exe should unpack to local directory and leave it in place
  def test_debug_extract
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--debug-extract"]))
      exe = exe_name("helloworld")
      pristine_env exe do
        assert_equal 0, Dir["ocr*"].size
        assert system(exe)
        assert_equal 1, Dir["ocr*"].size
      end
    end
  end

  # Test that the --output option allows us to specify a different exe name
  def test_output_option
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output", "goodbyeworld.exe"]))
      refute File.exist?(exe_name("helloworld"))
      assert File.exist?("goodbyeworld.exe")
    end
  end

  # Test that --output-dir produces a directory with the expected layout and
  # a working launch script.
  def test_output_dir
    with_fixture 'helloworld' do
      outdir = File.expand_path("helloworld_dir")
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output-dir", outdir]))

      assert Dir.exist?(outdir),               "--output-dir did not create directory"
      assert Dir.exist?(File.join(outdir, "bin")), "bin/ missing from output directory"
      assert Dir.exist?(File.join(outdir, "src")), "src/ missing from output directory"

      launch_script = if Gem.win_platform?
                        File.join(outdir, "helloworld.bat")
                      else
                        File.join(outdir, "helloworld.sh")
                      end
      assert File.exist?(launch_script), "Launch script not found: #{launch_script}"

      Bundler.with_original_env do
        if Gem.win_platform?
          assert system("cmd", "/c", launch_script)
        else
          assert system("sh", launch_script)
        end
      end
    ensure
      FileUtils.rm_rf(outdir)
    end
  end

  # Test that --output-zip produces a zip archive whose contents unpack to a
  # working directory layout with a functional launch script.
  def test_output_zip
    unless Gem.win_platform?
      skip "zip command not available" unless system("which zip > /dev/null 2>&1")
    end

    with_fixture 'helloworld' do
      zip_path = File.expand_path("helloworld.zip")
      assert system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output-zip", zip_path]))

      assert File.exist?(zip_path), "Zip file not created"
      assert File.size(zip_path) > 0, "Zip file is empty"

      Dir.mktmpdir(".ocrantest-zip-") do |tmpdir|
        if Gem.win_platform?
          assert system("powershell", "-NoProfile", "-Command",
                        "Expand-Archive -Path '#{zip_path}' -DestinationPath '#{tmpdir}' -Force")
          launch_script = File.join(tmpdir, "helloworld.bat")
        else
          assert system("unzip", "-q", zip_path, "-d", tmpdir)
          launch_script = File.join(tmpdir, "helloworld.sh")
        end

        assert File.exist?(launch_script), "Launch script missing from zip: #{launch_script}"
        assert Dir.exist?(File.join(tmpdir, "bin")), "bin/ missing from zip"
        assert Dir.exist?(File.join(tmpdir, "src")), "src/ missing from zip"

        Bundler.with_original_env do
          if Gem.win_platform?
            assert system("cmd", "/c", launch_script)
          else
            assert system("sh", launch_script)
          end
        end
      end
    end
  end

  # Test that we can specify a directory to be recursively included
  def test_directory_on_cmd_line
    with_fixture 'subdir' do
      assert system("ruby", ocran, "subdir.rb", "a", *DefaultArgs)
      exe = exe_name("subdir")
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Test that scripts can exit with a specific exit status code.
  def test_exitstatus
    with_fixture 'exitstatus' do
      assert system("ruby", ocran, "exitstatus.rb", *DefaultArgs)
      exe = exe_name("exitstatus")
      pristine_env exe do
        system(exe)
        assert_equal 167, $?.exitstatus
      end
    end
  end

  # Test that arguments are passed correctly to scripts.
  def test_arguments1
    with_fixture 'arguments' do
      assert system("ruby", ocran, "arguments.rb", *DefaultArgs)
      exe = exe_name("arguments")
      assert File.exist?(exe)
      pristine_env exe do
        system("#{exe} foo \"bar baz \\\"quote\\\"\"")
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
      exe = exe_name("arguments")
      assert File.exist?(exe)
      pristine_env exe do
        system(exe)
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
      exe = exe_name("arguments")
      assert File.exist?(exe)
      pristine_env exe do
        system("#{exe} \"bar baz \\\"quote\\\"\"")
        assert_equal 5, $?.exitstatus
      end
    end
  end

  # Test that arguments are passed correctly at build time.
  def test_buildarg
    with_fixture "buildarg" do
      args = DefaultArgs + [ "--", "--some-option" ]
      assert system("ruby", ocran, "buildarg.rb", *args)
      exe = exe_name("buildarg")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Test that the standard output from a script can be redirected to a
  # file.
  def test_stdout_redir
    with_fixture 'stdoutredir' do
      assert system("ruby", ocran, "stdoutredir.rb", *DefaultArgs)
      exe = exe_name("stdoutredir")
      assert File.exist?(exe)
      pristine_env exe do
        system("#{exe} > output.txt")
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
      exe = exe_name("stdinredir")
      assert File.exist?(exe)
      # Kernel.system("ruby -e \"system '#{exe}<input.txt';p $?\"")
      pristine_env exe, "input.txt" do
        system("#{exe} < input.txt")
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
      exe = exe_name("gdbmdll")
      with_env 'PATH' => '.' do
        pristine_env exe do
          system(exe)
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
      exe = exe_name("relativerequire")
      assert File.exist?(exe)
      pristine_env exe do
        system(exe)
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
      exe = exe_name("autoload")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
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
      exe = exe_name("autoloadmissing")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Test that Ocran picks up autoload statement nested in modules.
  def test_autoload_nested
    with_fixture 'autoloadnested' do
      assert system("ruby", ocran, "autoloadnested.rb", *DefaultArgs)
      exe = exe_name("autoloadnested")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Should find features via relative require paths, after script
  # changes to the right directory (Only valid for Ruby < 1.9.2).
  def test_relative_require_chdir_path
    with_fixture "relloadpath" do
      each_path_combo "bin/chdir1.rb" do |script|
        assert system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('chdir1')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
        exe = exe_name('chdir2')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
        exe = exe_name('external')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
        end
      end
    end
  end

  # Should pick up files from relative load path specified using the
  # RUBYLIB environment variable.
  def test_relative_require_rubylib
    with_fixture 'relloadpath' do
      each_path_combo "bin/external.rb", "lib", "bin/sub" do |script, *loadpaths|
        with_env 'RUBYLIB' => loadpaths.join(File::PATH_SEPARATOR) do
          assert system('ruby', ocran, script, *DefaultArgs)
        end
        exe = exe_name('external')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
        exe = exe_name('loadpath0')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
        exe = exe_name('loadpath1')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
        exe = exe_name('loadpath2')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
        exe = exe_name('loadpath3')
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
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
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Test that additional non-script files can be added to the
  # executable and used by the script.
  def test_resource
    with_fixture 'resource' do
      assert system("ruby", ocran, "resource.rb", "resource.txt", "res/resource.txt", *DefaultArgs)
      exe = exe_name("resource")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Test that when exceptions are thrown, no executable will be built.
  def test_exception
    with_fixture 'exception' do
      system("ruby \"#{ocran}\" exception.rb #{DefaultArgs.join(' ')} 2>NUL")
      assert $?.exitstatus != 0
      exe = exe_name("exception")
      refute File.exist?(exe)
    end
  end

  # Test that the RUBYOPT environment variable is preserved when --rubyopt is not passed
  def test_rubyopt
    with_fixture 'environment' do
      with_env "RUBYOPT" => "-rtime" do
        assert system("ruby", ocran, "environment.rb", *DefaultArgs)
        exe = exe_name("environment")
        pristine_env exe do
          assert system(exe)
          env = Marshal.load(File.open("environment.txt", "rb") { |f| f.read })
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
        exe = exe_name("environment")
        pristine_env exe do
          assert system(exe)
          env = Marshal.load(File.open("environment.txt", "rb") { |f| f.read })
          assert_equal specified_rubyopt, env['RUBYOPT']
        end
      end
    end
  end

  def test_exit
    with_fixture 'exit' do
      assert system("ruby", ocran, "exit.rb", *DefaultArgs)
      exe = exe_name("exit")
      pristine_env exe do
        assert File.exist?(exe)
        assert system(exe)
      end
    end
  end

  def test_ocran_executable_env
    with_fixture 'environment' do
      assert system("ruby", ocran, "environment.rb", *DefaultArgs)
      exe = exe_name("environment")
      pristine_env exe do
        assert system(exe)
        env = Marshal.load(File.open("environment.txt", "rb") { |f| f.read })
        expected_path = Gem.win_platform? ? File.expand_path(exe).tr('/','\\') : File.expand_path(exe)
        assert_equal expected_path, env['OCRAN_EXECUTABLE']
      end
    end
  end

  def test_hierarchy
    with_fixture 'hierarchy' do
      assert system("ruby", ocran, "hierarchy.rb", "assets/**/*", *DefaultArgs)
      exe = exe_name("hierarchy")
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  def test_temp_with_space
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      tempdir = File.expand_path("temporary directory")
      mkdir_p tempdir
      exe = exe_name("helloworld")
      pristine_env exe do
        with_env "TMP" => tempdir.tr('/','\\') do
          assert system(exe)
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
        exe = exe_name("helloworld")
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
        end
      end
    end
  end

  def test_abspath_outside
    with_fixture "helloworld" do
      mkdir "build"
      cd "build" do
        assert system("ruby", ocran, File.expand_path("../helloworld.rb"), *DefaultArgs)
        exe = exe_name("helloworld")
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
        end
      end
    end
  end

  def test_relpath
    with_fixture "helloworld" do
      assert system("ruby", ocran, "./helloworld.rb", *DefaultArgs)
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  def test_relpath_outside
    with_fixture "helloworld" do
      mkdir "build"
      cd "build" do
        assert system("ruby", ocran, "../helloworld.rb", *DefaultArgs)
        exe = exe_name("helloworld")
        assert File.exist?(exe)
        pristine_env exe do
          assert system(exe)
        end
      end
    end
  end

  # Should accept hierachical source code layout
  def test_srcroot
    with_fixture "srcroot" do
      assert system("ruby", ocran, "bin/srcroot.rb", "share/data.txt", *DefaultArgs)
      exe = exe_name("srcroot")
      assert File.exist?(exe)
      pristine_env exe do
        exe_path = File.expand_path(exe)
        systemRoot = Gem.win_platform? ? ENV["SystemRoot"] : "/"
        cd systemRoot do
          assert system(exe_path)
        end
      end
    end
  end

  # Should be able to build executables when script changes directory.
  def test_chdir
    with_fixture "chdir" do
      assert system("ruby", ocran, "chdir.rb", *DefaultArgs)
      exe = exe_name("chdir")
      assert File.exist?(exe)
      pristine_env exe do
        exe_path = File.expand_path(exe)
        systemRoot = Gem.win_platform? ? ENV["SystemRoot"] : "/"
        cd systemRoot do
          assert system(exe_path)
        end
      end
    end
  end

  # Test that the --chdir-first option changes directory before exe starts script
  def test_chdir_first
    with_fixture 'writefile' do
      # Control test; make sure the writefile script works as expected under default options
      assert system("ruby", ocran, "writefile.rb", *(DefaultArgs))
      exe = exe_name("writefile")
      pristine_env exe do
        refute File.exist?("output.txt")
        assert system(exe)
        assert File.exist?("output.txt")
      end

      assert system("ruby", ocran, "writefile.rb", *(DefaultArgs + ["--chdir-first"]))
      pristine_env exe do
        refute File.exist?("output.txt")
        assert system(exe)
        # If the script ran in its inst directory, then our working dir still shouldn't have any output.txt
        refute File.exist?("output.txt")
      end
    end
  end

  # Would be nice if OCRAN could build from source located beneath the
  # Ruby installation too.
  def test_exec_prefix
    path = File.join(RbConfig::CONFIG["exec_prefix"], "ocrantempsrc")
    with_fixture "helloworld", path do
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
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
      exe = exe_name("check_includes")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe, number_of_files.to_s)
      end
    end
  end

  # Hello world test. Test that we can build and run executables.
  def test_nonexistent_temp
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        with_env "TEMP" => "c:\\thispathdoesnotexist12345", "TMP" => "c:\\thispathdoesnotexist12345" do
          assert File.exist?(exe)
          system("#{exe} 2>NUL")
          assert File.exist?(exe)
        end
      end
    end
  end

  # Should be able to build an installer using Inno Setup.
  def test_innosetup
    skip "InnoSetup not available" unless Gem.win_platform?
    if ENV["GITHUB_ACTIONS"]
      assert system("where ISCC >NUL 2>&1"), "ISCC not found in PATH; InnoSetup install step may have failed"
    else
      skip unless system("where ISCC >NUL 2>&1")
    end
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
      exe = exe_name("helloworld-debug")
      pristine_env exe do
        require 'open3'
        Open3.popen3(exe) do |_stdin, _stdout, stderr, wait_thr|
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
      exe = exe_name("helloworld")
      assert system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      assert File.exist?(exe)

      multibyte_dir = "äあ💎"

      pristine_env exe do
        mkdir_p multibyte_dir
        cp exe, multibyte_dir
        Dir.chdir(multibyte_dir) do
          assert system(exe)
        end
      end
    end
  end

  # Tests building and running a Ruby script with multibyte (UTF-8) characters
  # in its filename. Skipped unless the console code page is UTF-8 (65001),
  # as ruby.exe misinterprets arguments under non-UTF-8 environments.
  def test_multibyte_script_filename

    if Gem.win_platform?
      cp = `chcp`.force_encoding(Encoding::BINARY)[/\d+/] || "unknown"
      unless cp == "65001"
        skip "Skipped: console code page must be UTF-8 (65001), got #{cp}"
      end
    else
      unless Encoding.find('locale') == Encoding::UTF_8 || Encoding.default_external == Encoding::UTF_8
        skip "Skipped: system locale must be UTF-8, got #{Encoding.find('locale')}"
      end
    end

    with_fixture 'multibyte_script' do
      script = "äあ💎.rb"
      assert system("ruby", ocran, script, *DefaultArgs)
      exe_name = script.sub(/\.rb$/, '')
      exe_name += '.exe' if Gem.win_platform?
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
      exe = exe_name("resource")
      assert File.exist?(exe)
      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Tests that OCRAN can handle resource files stored in a directory
  # with multibyte (UTF-8) characters in its name.
  def test_multibyte_resource_dir
    with_fixture 'multibyte_dir' do
      assert system("ruby", ocran, "resource.rb", "äあ💎/äあ💎.txt", *DefaultArgs)
      assert File.exist?(exe_name("resource"))
      pristine_env exe_name("resource") do
        assert system(exe_name("resource"))
      end
    end
  end

  # Test that code-signed executables still work
  def test_codesigning_support
    skip "Only for windows" unless Gem.win_platform?
    with_fixture 'helloworld' do
      each_path_combo "helloworld.rb" do |script|
        assert system("ruby", ocran, script, *DefaultArgs)
        FakeCodeSigner.new(input_file: "helloworld.exe",
                           output_file: "helloworld-signed.exe",
                           padding: rand(20)).sign

        pristine_env "helloworld.exe", "helloworld-signed.exe" do
          assert system("helloworld.exe")
          assert system("helloworld-signed.exe")
        end
      end
    end
  end


  # Tests that a packaged Tk application builds and runs successfully.
  # --gem-full=tk includes all Tk gem files; --add-all-core
  # ensures runtime Ruby core coverage. The fixture exits immediately at runtime
  # so we can verify a clean exit without needing a display or user interaction.
  def test_tk
    skip "tk gem not available" unless Gem::Specification.find_all_by_name("tk").any? #or ENV["GITHUB_ACTIONS"]
    with_fixture "tk" do
      assert system("ruby", ocran, "tk.rb", *DefaultArgs)
      exe = exe_name("tk")
      assert File.exist?(exe)
      pristine_env exe do
         assert system(exe)
         puts "sucessfully tested tk" if $?.success?
      end
    end
  end

  # Tests that a packaged Glimmer DSL for LibUI application builds and runs
  # successfully. libui ships its own libui.dll in the gem's vendor/ directory
  # and loads it via Fiddle; OCRAN detects it through DLL scanning because the
  # gem lives under exec_prefix. --gem-full=libui ensures the vendor/libui.dll
  # is included. The fixture exits immediately at runtime so we can verify a
  # clean exit without needing a display or user interaction.
  def test_glimmer_libui
    skip "glimmer-dsl-libui gem not available" unless Gem::Specification.find_all_by_name("glimmer-dsl-libui").any? or ENV["GITHUB_ACTIONS"]
    with_fixture "glimmer_libui" do
      assert system("ruby", ocran, "glimmer_libui.rb", *DefaultArgs)
      assert File.exist?(exe_name("glimmer_libui"))
      pristine_env exe_name("glimmer_libui") do
        assert system(exe_name("glimmer_libui"))
      end
    end
  end

  # Regression test: zlib.so has a companion zlib.so-assembly.manifest and
  # zlib1.dll in archdir. Without them the SxS activation context fails with
  # error 14001 at runtime. Verifies that compress/decompress round-trips work.
  def test_zlib
    skip "SxS manifest test is Windows-only" unless Gem.win_platform?
    with_fixture 'zlib' do
      assert system("ruby", ocran, "zlib.rb", *DefaultArgs)
      assert File.exist?(exe_name("zlib"))
      pristine_env exe_name("zlib") do
        assert system(exe_name("zlib"))
      end
    end
  end

  # Tests that a script using net/http HTTPS works correctly when packaged and
  # that OCRAN bundles the SSL certificate into the extraction directory.
  # OCRAN automatically sets SSL_CERT_FILE to the extracted cert path, so the
  # fixture writes the effective cert path to cert_path.txt for verification.
  def test_openssl_https
    with_fixture 'openssl_https' do
      assert system("ruby", ocran, "openssl_https.rb", *DefaultArgs)
      assert File.exist?(exe_name("openssl_https"))
      pristine_env exe_name("openssl_https") do
        assert system(exe_name("openssl_https"))
        if Gem.win_platform?
          cert_path = File.read("cert_path.txt")
          # OCRAN extracts to a temp directory named ocranXXXXXX; the bundled
          # cert is placed there and SSL_CERT_FILE is set to that path.
          assert cert_path.include?("ocran"),
                 "SSL cert should be loaded from the OCRAN extraction dir, got: #{cert_path}"
        end
      end
    end
  end

  # Tests that a script can use a custom cacert.pem placed next to the exe.
  # The cacert.pem is downloaded from curl.se and included alongside the exe;
  # the fixture sets SSL_CERT_FILE to that file before OpenSSL is loaded.
  # Also verifies that a non-existent/invalid cert causes an SSL error.
  def test_openssl_https_cacert
    skip "cacert.pem invalidation test is Windows-only (POSIX systems fall back to system certs)" unless Gem.win_platform?
    with_fixture 'openssl_https_cacert' do
      assert system("ruby", ocran, "openssl_https_cacert.rb", *DefaultArgs)
      exe = exe_name("openssl_https_cacert")
      assert File.exist?(exe)

      pristine_env exe, "cacert.pem" do
        assert system(exe)
      end

      # With an invalid cert file SSL verification must fail, confirming the
      # fixture actually uses cacert.pem rather than the system cert store.
      pristine_env exe do
        File.write("cacert.pem", "not a valid certificate")
        refute system(exe),
               "Expected SSL failure when cacert.pem is invalid"
      end
    end
  end

  # Tests that --macosx-bundle produces a valid .app bundle structure and
  # that the executable inside it runs correctly.
  def test_macosx_bundle
    skip "macOS app bundle test is macOS-only" unless RUBY_PLATFORM.include?("darwin")
    with_fixture 'helloworld' do
      assert system("ruby", ocran, "helloworld.rb", "--macosx-bundle", *DefaultArgs)

      bundle = "helloworld.app"
      assert Dir.exist?(bundle), "Expected #{bundle} directory to exist"
      assert File.exist?(File.join(bundle, "Contents", "Info.plist")), "Expected Info.plist"

      exe = File.join(bundle, "Contents", "MacOS", "helloworld")
      assert File.exist?(exe), "Expected executable at Contents/MacOS/helloworld"
      assert File.executable?(exe), "Expected Contents/MacOS/helloworld to be executable"

      pristine_env exe do
        assert system(exe)
      end
    end
  end

  # Tests --macosx-bundle with a custom name, bundle-id, and icon.
  def test_macosx_bundle_custom
    skip "macOS app bundle test is macOS-only" unless RUBY_PLATFORM.include?("darwin")
    with_fixture 'helloworld' do
      # Create a minimal placeholder .icns file (not a real icon, just tests the copy)
      File.write("test.icns", "placeholder")

      assert system("ruby", ocran, "helloworld.rb",
                    "--macosx-bundle",
                    "--output", "MyApp",
                    "--bundle-id", "com.example.myapp",
                    "--icon", "test.icns",
                    *DefaultArgs)

      bundle = "MyApp.app"
      assert Dir.exist?(bundle)

      plist = File.read(File.join(bundle, "Contents", "Info.plist"))
      assert plist.include?("com.example.myapp"), "Expected bundle identifier in Info.plist"
      assert plist.include?("MyApp"), "Expected app name in Info.plist"
      assert plist.include?("CFBundleIconFile"), "Expected icon entry in Info.plist"

      assert File.exist?(File.join(bundle, "Contents", "Resources", "AppIcon.icns"))
      assert File.exist?(File.join(bundle, "Contents", "MacOS", "MyApp"))
    end
  end
end
