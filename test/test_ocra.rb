require "minitest/autorun"

require "tmpdir"
require "tmpdir"
require "fileutils"
require "open3"
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

  # Runs a command with its output captured, and asserts that it succeeded.
  #
  # A bare `assert system(...)` throws the child's stdout and stderr at the
  # console, where the test runner's own output buries it, and then reports
  # nothing but "Expected false to be truthy". Since the child is the only
  # thing that knows why a build or a packaged executable failed, its
  # diagnostics belong in the failure message.
  def assert_system(*args, message: nil)
    output, status = capture_system(*args)
    details = output.strip.empty? ? "(no output)" : output
    assert status&.success?,
           [message || "Command failed: #{describe_command(args)}",
            "exit status: #{status ? status.exitstatus.inspect : "not started"}",
            details].join("\n")
  end

  # Runs a command, merging its stderr into its stdout. Returns the output
  # and the exit status, the latter nil if the command could not be started
  # at all - Open3 raises for that where Kernel#system just returns nil.
  def capture_system(*args)
    puts describe_command(args) if ENV["OCRAN_VERBOSE_TEST"]
    output, status = Open3.capture2e(*args)
    print output if ENV["OCRAN_VERBOSE_TEST"]
    [output, status]
  rescue SystemCallError => e
    [e.message, nil]
  end

  def describe_command(args)
    args.map { |arg| arg.is_a?(Hash) ? arg.inspect : arg.to_s }.join(" ")
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
        assert_system("ruby", ocran, script, *DefaultArgs)
        assert File.exist?(exe_name("helloworld"))
        pristine_env exe_name("helloworld") do
          assert_system(exe_name("helloworld"))
        end
      end
    end
  end

  # Locates a cosmocc toolchain for the --cosmo end-to-end test: honors
  # the COSMOCC environment variable (cosmocc binary or toolchain dir),
  # otherwise looks for cosmocc in PATH. Returns nil if unavailable.
  def find_cosmocc
    env = ENV["COSMOCC"]
    return env if env && !env.empty? && File.exist?(env)
    path = `which cosmocc 2>/dev/null`.chomp
    path.empty? ? nil : path
  end

  # --cosmo toolchain path resolution: accepts the cosmocc binary itself,
  # the toolchain root (containing bin/cosmocc), or the bin directory,
  # and raises clear errors otherwise. Runs without a real toolchain.
  def test_cosmo_toolchain_resolution
    # Toolchain discovery is POSIX-only: it relies on the executable
    # bit, which Windows does not have (File.executable? is driven by
    # PATHEXT there). Cosmo builds are rejected on Windows build hosts
    # anyway, so there is nothing to exercise.
    skip "cosmo toolchain discovery is POSIX-only" if Gem.win_platform?
    # Kernel#load, guarded: Ocran::Option loads this file the same way (see
    # Option#load_cosmo_toolchain), and mixing load with require_relative
    # would run the file twice and warn about redefined constants.
    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    with_tmpdir do
      mkdir_p "toolchain/bin"
      cc = File.expand_path("toolchain/bin/cosmocc")
      File.write(cc, "#!/bin/sh\n")
      File.chmod(0755, cc)

      assert_equal cc, Ocran::CosmoToolchain.resolve_cc("toolchain")
      assert_equal cc, Ocran::CosmoToolchain.resolve_cc("toolchain/bin")
      assert_equal cc, Ocran::CosmoToolchain.resolve_cc(cc)

      err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.resolve_cc("no/such/path") }
      assert_match(/cosmocc not found/, err.message)

      err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.resolve_cc(nil) }
      assert_match(/--cosmo requires a path/, err.message)

      unless Gem.win_platform?
        File.chmod(0644, cc)
        err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.resolve_cc("toolchain") }
        assert_match(/not executable/, err.message)
      end
    end
  end

  # End-to-end --cosmo build: compiles the stub from src/ with cosmocc at
  # packaging time, packages helloworld with the resulting APE stub
  # (default output extension .com), and runs the binary. Skipped unless
  # a cosmocc toolchain is available (COSMOCC env var or cosmocc in PATH).
  def test_cosmo_helloworld
    skip "--cosmo requires a POSIX build host" if Gem.win_platform?
    cosmocc = find_cosmocc
    skip "cosmocc not found (set COSMOCC or add cosmocc to PATH)" unless cosmocc

    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", *DefaultArgs, "--cosmo", cosmocc)
      assert File.exist?("helloworld.com")
      # APE binaries start with the "MZqFpD" MZ/shell polyglot magic
      assert_equal "MZqFpD", File.binread("helloworld.com", 6)
      pristine_env "helloworld.com" do
        # Invoke through the shell: an APE bootstraps itself via its
        # shell-script header on hosts without APE binfmt support.
        assert_system("./helloworld.com")
      end
    end
  end

  # Locates a cosmopolitan-built Ruby APE (ruby.com) for the --cosmo-ruby
  # end-to-end tests via the COSMO_RUBY environment variable. Returns nil
  # if unavailable.
  def find_cosmo_ruby
    env = ENV["COSMO_RUBY"]
    env && !env.empty? && File.file?(env) ? env : nil
  end

  # Common gate for the --cosmo-ruby end-to-end tests: requires a POSIX
  # build host, a cosmocc toolchain and a cosmopolitan Ruby payload.
  def cosmo_ruby_prereqs
    skip "--cosmo requires a POSIX build host" if Gem.win_platform?
    cosmocc = find_cosmocc
    skip "cosmocc not found (set COSMOCC or add cosmocc to PATH)" unless cosmocc
    cosmo_ruby = find_cosmo_ruby
    skip "cosmopolitan Ruby not found (set COSMO_RUBY to a ruby.com APE)" unless cosmo_ruby
    [cosmocc, cosmo_ruby]
  end

  # --cosmo-ruby path validation: accepts an existing APE file, rejects
  # missing paths and non-APE files. Runs without a real payload.
  def test_cosmo_ruby_resolution
    # Kernel#load, guarded: Ocran::Option loads this file the same way (see
    # Option#load_cosmo_toolchain), and mixing load with require_relative
    # would run the file twice and warn about redefined constants.
    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    with_tmpdir do
      File.binwrite("ruby.com", "MZqFpD='\n" + "\0" * 16)
      assert_equal File.expand_path("ruby.com"), Ocran::CosmoToolchain.resolve_ruby("ruby.com")

      File.binwrite("not-an-ape", "\x7fELF\0\0\0\0")
      err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.resolve_ruby("not-an-ape") }
      assert_match(/does not look like an APE/, err.message)

      err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.resolve_ruby("missing.com") }
      assert_match(/not found/, err.message)

      err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.resolve_ruby(nil) }
      assert_match(/--cosmo-ruby requires a path/, err.message)
    end
  end

  # Toolchain discovery precedence, so that --cosmo-ruby alone is enough:
  # an explicit --cosmo path beats everything, then the COSMOCC
  # environment variable, then cosmocc in PATH, then the conventional
  # install locations (newest version first); a clear error when nothing
  # is found. Runs with fake toolchains, no real cosmocc needed.
  def test_cosmo_toolchain_discovery
    # Toolchain discovery is POSIX-only: it relies on the executable
    # bit, which Windows does not have (File.executable? is driven by
    # PATHEXT there). Cosmo builds are rejected on Windows build hosts
    # anyway, so there is nothing to exercise.
    skip "cosmo toolchain discovery is POSIX-only" if Gem.win_platform?
    # Kernel#load, guarded: Ocran::Option loads this file the same way (see
    # Option#load_cosmo_toolchain), and mixing load with require_relative
    # would run the file twice and warn about redefined constants.
    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    with_tmpdir do
      # Four fake toolchains, one per discovery mechanism. The conventional
      # location holds two versions to check that the newest one wins.
      %w[explicit/bin env/bin pathdir home/.cosmocc/3.9.2/bin
         home/.cosmocc/4.0.10/bin].each do |dir|
        mkdir_p dir
        cc = File.join(dir, "cosmocc")
        File.write(cc, "#!/bin/sh\n")
        File.chmod(0755, cc)
      end
      explicit = File.expand_path("explicit/bin/cosmocc")
      from_env = File.expand_path("env/bin/cosmocc")
      from_path = File.expand_path("pathdir/cosmocc")
      newest = File.expand_path("home/.cosmocc/4.0.10/bin/cosmocc")
      home = File.expand_path("home")
      full = { "COSMOCC" => File.expand_path("env"), "PATH" => File.expand_path("pathdir"),
               "HOME" => home }

      # An explicit --cosmo overrides every discovered toolchain, so a
      # development or CI toolchain can be used instead of the host's.
      assert_equal explicit, Ocran::CosmoToolchain.require_cc(File.expand_path("explicit"), full)
      # COSMOCC beats PATH beats the conventional locations.
      assert_equal from_env, Ocran::CosmoToolchain.require_cc(nil, full)
      assert_equal from_path, Ocran::CosmoToolchain.require_cc(nil, full.reject { |k, _| k == "COSMOCC" })
      assert_equal newest, Ocran::CosmoToolchain.require_cc(nil, { "HOME" => home, "PATH" => "" })

      # A COSMOCC that does not name a toolchain is an error, not a silent
      # fallback to some other toolchain on the machine.
      err = assert_raises(RuntimeError) do
        Ocran::CosmoToolchain.require_cc(nil, full.merge("COSMOCC" => File.expand_path("nope")))
      end
      assert_match(/COSMOCC=.*does not name a usable cosmocc toolchain/, err.message)

      # Nothing anywhere: the message has to name all the ways to fix it.
      # Only checkable when this machine has no cosmocc in a system-wide
      # conventional location (/opt/cosmocc, ...).
      mkdir_p "emptyhome"
      empty = { "HOME" => File.expand_path("emptyhome"), "PATH" => File.expand_path("emptyhome") }
      unless Ocran::CosmoToolchain.conventional_cc(empty)
        err = assert_raises(RuntimeError) { Ocran::CosmoToolchain.require_cc(nil, empty) }
        assert_match(/no cosmocc toolchain found/, err.message)
        assert_match(/COSMOCC/, err.message)
        assert_match(/PATH/, err.message)
        assert_match(/--cosmo/, err.message)
        assert_match(/cosmo\.zip/, err.message)
      end
    end
  end

  # --cosmo-ruby alone is a complete command line: the cosmocc toolchain is
  # inferred (here from COSMOCC), and the output defaults to the APE .com
  # extension just as with an explicit --cosmo.
  def test_cosmo_ruby_infers_toolchain
    skip "--cosmo-ruby requires a POSIX build host" if Gem.win_platform?
    require_relative "../lib/ocran/option"
    with_fixture "helloworld" do
      File.binwrite("fake-ruby.com", "MZqFpD='\n")
      mkdir_p "toolchain/bin"
      cc = File.expand_path("toolchain/bin/cosmocc")
      File.write(cc, "#!/bin/sh\n")
      File.chmod(0755, cc)

      saved = ENV["COSMOCC"]
      begin
        ENV["COSMOCC"] = File.expand_path("toolchain")
        option = Ocran::Option.new
        option.parse(["helloworld.rb", "--cosmo-ruby", "fake-ruby.com"])
      ensure
        saved.nil? ? ENV.delete("COSMOCC") : ENV["COSMOCC"] = saved
      end

      assert_equal cc, option.cosmo_cc
      assert_equal File.expand_path("fake-ruby.com"), option.cosmo_ruby
      assert_equal ".com", option.output_executable.extname
    end
  end

  # Regression: parsing --cosmo/--cosmo-ruby must not add anything to
  # $LOADED_FEATURES. OCRAN detects an application's dependencies by diffing
  # $LOADED_FEATURES around the dependency run, and the "before" snapshot is
  # taken *before* the command line is parsed (Runner#initialize) - so a
  # library loaded while parsing is indistinguishable from one the user's
  # script required and gets packed into the application. When
  # cosmo_toolchain.rb was pulled in with require_relative it was packed as
  # an application source file, which also pushed the whole application into
  # a deeper src/ subdirectory (the src prefix is the common parent of all
  # source files).
  def test_cosmo_options_do_not_load_features
    skip "--cosmo requires a POSIX build host" if Gem.win_platform?
    require_relative "../lib/ocran/option"
    with_fixture "helloworld" do
      File.binwrite("fake-ruby.com", "MZqFpD='\n")
      mkdir_p "toolchain/bin"
      cc = File.expand_path("toolchain/bin/cosmocc")
      File.write(cc, "#!/bin/sh\n")
      File.chmod(0755, cc)

      before = $LOADED_FEATURES.dup
      Ocran::Option.new.parse(["helloworld.rb", "--cosmo", "toolchain",
                               "--cosmo-ruby", "fake-ruby.com"])
      assert_empty($LOADED_FEATURES - before,
                   "parsing the cosmo options must not load features; they would be packed into the app")
    end
  end

  # End-to-end single-option build: --cosmo-ruby on its own, with the
  # cosmocc toolchain discovered from the environment instead of being
  # named on the command line. This is the headline form of the feature,
  # so it gets the full isolation check: the produced .com must run under
  # the EMBEDDED x86_64-cosmo interpreter in an empty directory with an
  # empty environment.
  def test_cosmo_ruby_helloworld_single_option
    cosmocc, cosmo_ruby = cosmo_ruby_prereqs
    with_fixture "cosmoruby" do
      assert_system({ "COSMOCC" => cosmocc }, "ruby", ocran, "cosmoruby.rb",
                    *DefaultArgs, "--cosmo-ruby", cosmo_ruby)
      assert File.exist?("cosmoruby.com")
      assert_equal "MZqFpD", File.binread("cosmoruby.com", 6)
      pristine_env "cosmoruby.com" do
        out = `env -i ./cosmoruby.com`
        assert $?.success?, "cosmoruby.com failed, output: #{out}"
        assert_match(/x86_64-cosmo/, out)
        refute_match(/#{Regexp.escape(RUBY_PLATFORM)}/, out) unless RUBY_PLATFORM.include?("cosmo")
      end
    end
  end

  # End-to-end --cosmo-ruby build with an explicit --cosmo toolchain (the
  # override path): the produced .com bundles an APE stub AND an APE Ruby,
  # so in an isolated environment (env -i, empty dir) the app must run
  # under the EMBEDDED x86_64-cosmo interpreter — not the build host's Ruby.
  def test_cosmo_ruby_helloworld
    cosmocc, cosmo_ruby = cosmo_ruby_prereqs
    with_fixture "cosmoruby" do
      assert_system("ruby", ocran, "cosmoruby.rb", *DefaultArgs,
                    "--cosmo", cosmocc, "--cosmo-ruby", cosmo_ruby)
      assert File.exist?("cosmoruby.com")
      assert_equal "MZqFpD", File.binread("cosmoruby.com", 6)
      pristine_env "cosmoruby.com" do
        out = `env -i ./cosmoruby.com`
        assert $?.success?, "cosmoruby.com failed, output: #{out}"
        assert_match(/x86_64-cosmo/, out)
        refute_match(/#{Regexp.escape(RUBY_PLATFORM)}/, out) unless RUBY_PLATFORM.include?("cosmo")
      end
    end
  end

  # An app requiring stdlib (json, yaml) must resolve it from the
  # cosmopolitan Ruby's embedded standard library, not the host's.
  def test_cosmo_ruby_stdlib
    cosmocc, cosmo_ruby = cosmo_ruby_prereqs
    with_fixture "cosmoruby_stdlib" do
      assert_system("ruby", ocran, "stdlib.rb", *DefaultArgs,
                    "--cosmo", cosmocc, "--cosmo-ruby", cosmo_ruby)
      assert File.exist?("stdlib.com")
      pristine_env "stdlib.com" do
        out = `env -i ./stdlib.com`
        assert $?.success?, "stdlib.com failed, output: #{out}"
        assert_match(/json:42/, out)
        assert_match(/yaml:value/, out)
        assert_match(/platform:x86_64-cosmo/, out)
      end
    end
  end

  # A pure-Ruby gem installed on the build host is packed as usual and
  # activated by the cosmopolitan Ruby through GEM_PATH.
  def test_cosmo_ruby_gem
    cosmocc, cosmo_ruby = cosmo_ruby_prereqs
    begin
      Gem::Specification.find_by_name("mime-types")
    rescue Gem::LoadError
      skip "pure-Ruby test gem 'mime-types' is not installed on the build host"
    end
    with_fixture "cosmoruby_gem" do
      assert_system("ruby", ocran, "gemapp.rb", *DefaultArgs,
                    "--cosmo", cosmocc, "--cosmo-ruby", cosmo_ruby)
      assert File.exist?("gemapp.com")
      pristine_env "gemapp.com" do
        out = `env -i ./gemapp.com`
        assert $?.success?, "gemapp.com failed, output: #{out}"
        assert_match(/gem:txt/, out)
        assert_match(/platform:x86_64-cosmo/, out)
      end
    end
  end

  # Unit test for the --cosmo-ruby gem classification. A gem is native -
  # and thus unusable under the statically linked, dlopen-less payload -
  # either because it declares extensions (source install) or because it
  # ships prebuilt binaries (precompiled platform gem, whose extensions
  # array is EMPTY). Native gems the payload provides itself must be
  # skipped so the payload's own copy serves; native gems it does not
  # provide must fail the build.
  def test_cosmo_gem_disposition
    require_relative "../lib/ocran/direction"

    with_tmpdir do
      # Pure Ruby gem
      mkdir_p "pure/lib"
      File.write("pure/lib/pure.rb", "")
      pure = Gem::Specification.new { |s| s.name = "pure"; s.version = "1.0" }
      pure.define_singleton_method(:gem_dir) { File.expand_path("pure") }
      pure.define_singleton_method(:extension_dir) { File.expand_path("no/such/dir") }

      # Precompiled platform gem: no declared extensions, but a prebuilt
      # .so shipped inside the gem directory (e.g. sqlite3-x86_64-linux-gnu)
      mkdir_p "prebuilt/lib/prebuilt/3.3"
      File.write("prebuilt/lib/prebuilt.rb", "")
      File.write("prebuilt/lib/prebuilt/3.3/prebuilt_native.so", "")
      prebuilt = Gem::Specification.new { |s| s.name = "prebuilt"; s.version = "1.0" }
      prebuilt.define_singleton_method(:gem_dir) { File.expand_path("prebuilt") }
      prebuilt.define_singleton_method(:extension_dir) { File.expand_path("no/such/dir") }

      # Source-installed native gem: declares extensions, the built .so
      # lives in the separate extension directory
      mkdir_p "source/lib"
      mkdir_p "ext_dir"
      File.write("ext_dir/source.so", "")
      source = Gem::Specification.new do |s|
        s.name = "source"
        s.version = "1.0"
        s.extensions = ["ext/source/extconf.rb"]
      end
      source.define_singleton_method(:gem_dir) { File.expand_path("source") }
      source.define_singleton_method(:extension_dir) { File.expand_path("ext_dir") }

      assert_empty Ocran::Direction.gem_native_binaries(pure)
      refute_empty Ocran::Direction.gem_native_binaries(prebuilt)
      refute_empty Ocran::Direction.gem_native_binaries(source)

      # Pure Ruby gems are packed regardless of what the payload provides
      assert_equal :pack, Ocran::Direction.cosmo_gem_disposition(pure, [])[0]
      assert_equal :pack, Ocran::Direction.cosmo_gem_disposition(pure, ["pure"])[0]

      # The precompiled platform gem must be recognized as native even
      # though spec.extensions is empty
      assert_empty prebuilt.extensions
      assert_equal :payload_provides,
                   Ocran::Direction.cosmo_gem_disposition(prebuilt, ["prebuilt"])[0]
      assert_equal :incompatible,
                   Ocran::Direction.cosmo_gem_disposition(prebuilt, [])[0]

      assert_equal :payload_provides,
                   Ocran::Direction.cosmo_gem_disposition(source, ["source"])[0]
      assert_equal :incompatible,
                   Ocran::Direction.cosmo_gem_disposition(source, [])[0]

      # Build messages name the reason a gem counts as native
      assert_match(/prebuilt_native\.so/,
                   Ocran::Direction.cosmo_native_reason(prebuilt, Ocran::Direction.gem_native_binaries(prebuilt)))
      assert_match(/extensions/,
                   Ocran::Direction.cosmo_native_reason(source, Ocran::Direction.gem_native_binaries(source)))
    end
  end

  # End-to-end: a PRECOMPILED PLATFORM gem (sqlite3-x.y.z-x86_64-linux-gnu)
  # that the cosmopolitan Ruby payload also provides must not be packed at
  # all - neither its .so (which cannot load) nor its .rb files, which would
  # shadow the payload's own copy and can mismatch the statically linked C
  # extension. The app must run against the payload's sqlite3.
  def test_cosmo_ruby_precompiled_platform_gem
    cosmocc, cosmo_ruby = cosmo_ruby_prereqs
    begin
      spec = Gem::Specification.find_by_name("sqlite3")
    rescue Gem::LoadError
      skip "test gem 'sqlite3' is not installed on the build host"
    end
    unless spec.extensions.empty? && !Dir.glob("**/*.so", base: spec.gem_dir).empty?
      skip "installed sqlite3 is not a precompiled platform gem (gem install sqlite3 to get one)"
    end
    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    unless Ocran::CosmoToolchain.query_ruby(cosmo_ruby)[:gem_names].include?("sqlite3")
      skip "the cosmopolitan Ruby payload does not provide sqlite3"
    end

    with_fixture "cosmoruby_native_gem" do
      out = IO.popen(["ruby", ocran, "nativegem.rb", "--no-lzma", "--verbose",
                      "--cosmo", cosmocc, "--cosmo-ruby", cosmo_ruby],
                     err: [:child, :out], &:read)
      assert $?.success?, "ocran failed, output: #{out.lines.last(20).join}"
      # Keep failure output small: only report the sqlite3-related lines.
      sqlite_lines = out.lines.grep(/sqlite3/).first(10).join
      assert out.include?("provides its own sqlite3"),
             "expected the host sqlite3 gem to be skipped as provided by the payload:\n#{sqlite_lines}"
      packed = out.lines.grep(/\Acp .*sqlite3/)
      assert_empty packed, "host sqlite3 gem files must not be packed:\n#{packed.first(10).join}"

      assert File.exist?("nativegem.com")
      pristine_env "nativegem.com" do
        run = `env -i ./nativegem.com`
        assert $?.success?, "nativegem.com failed, output: #{run}"
        assert_match(/sqlite:7/, run)
        assert_match(/platform:x86_64-cosmo/, run)
      end
    end
  end

  # Detection of the capability the compiler-free ZIP packaging mode needs:
  # an interpreter that runs an embedded /zip/main.rb. It is recognized by
  # the name of the opt-out environment variable, which only a build with
  # the hook contains - anywhere in the binary, including across the
  # boundary of the chunks the scan reads.
  def test_cosmo_zip_main_detection
    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    marker = Ocran::CosmoToolchain::ZIP_MAIN_MARKER
    chunk = Ocran::CosmoToolchain::SCAN_CHUNK_SIZE

    with_tmpdir do
      File.binwrite("without.com", "MZqFpD='\n" + ("\0" * 4096))
      refute Ocran::CosmoToolchain.zip_main_support?("without.com")

      File.binwrite("with.com", "MZqFpD='\n" + ("\0" * 4096) + marker + ("\0" * 4096))
      assert Ocran::CosmoToolchain.zip_main_support?("with.com")

      # The marker must still be found when it straddles two reads.
      split_at = chunk - (marker.bytesize / 2)
      File.binwrite("split.com", ("\0" * split_at) + marker + ("\0" * 16))
      assert Ocran::CosmoToolchain.zip_main_support?("split.com")
    end
  end

  # Option surface: --cosmo-ruby alone selects ZIP packaging when the given
  # interpreter supports it, and then needs NO cosmocc toolchain at all -
  # that is the whole point of the mode. An explicit --cosmo asks for the
  # launcher stub instead, and an interpreter without the hook falls back
  # to it automatically.
  def test_cosmo_zip_option_surface
    skip "--cosmo-ruby requires a POSIX build host" if Gem.win_platform?
    require_relative "../lib/ocran/option"
    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    marker = Ocran::CosmoToolchain::ZIP_MAIN_MARKER

    with_fixture "helloworld" do
      File.binwrite("zipmain.com", "MZqFpD='\n#{marker}\n")
      File.binwrite("plain.com", "MZqFpD='\n")
      mkdir_p "toolchain/bin"
      cc = File.expand_path("toolchain/bin/cosmocc")
      File.write(cc, "#!/bin/sh\n")
      File.chmod(0755, cc)

      # No toolchain reachable anywhere: COSMOCC unset, empty PATH, a HOME
      # with no conventional install. --cosmo-ruby still has to work.
      with_env "COSMOCC" => nil, "PATH" => "", "HOME" => File.expand_path(".") do
        ENV.delete("COSMOCC")
        if Ocran::CosmoToolchain.find_cc(ENV)
          skip "this host has a cosmocc in a conventional location"
        end

        option = Ocran::Option.new
        option.parse(["helloworld.rb", "--cosmo-ruby", "zipmain.com"])
        assert option.cosmo_zip?, "an interpreter with the hook must be packaged by ZIP injection"
        assert_nil option.cosmo_cc, "ZIP packaging must not require a cosmocc toolchain"
        assert_equal ".com", option.output_executable.extname

        # Without the hook there is nothing to inject into, so the launcher
        # stub - and a toolchain - are needed again.
        err = assert_raises(RuntimeError) do
          Ocran::Option.new.parse(["helloworld.rb", "--cosmo-ruby", "plain.com"])
        end
        assert_match(/no cosmocc toolchain found/, err.message)
      end

      # An explicit --cosmo forces the launcher stub even for an
      # interpreter that could carry the application itself.
      option = Ocran::Option.new
      option.parse(["helloworld.rb", "--cosmo", "toolchain", "--cosmo-ruby", "zipmain.com"])
      refute option.cosmo_zip?
      assert_equal cc, option.cosmo_cc

      # Output formats that are not a single binary keep the stub too.
      option = Ocran::Option.new
      option.parse(["helloworld.rb", "--cosmo", "toolchain", "--cosmo-ruby", "zipmain.com",
                    "--output-dir", "out"])
      refute option.cosmo_zip?
    end
  end

  # The ZIP writer: OCRAN appends to an archive that is already inside an
  # executable, so it must produce entries a reader can find through the
  # central directory, with the UNIX file type bits set (without S_IFREG a
  # member is not a regular file and Ruby's own load refuses to open it).
  def test_zip_writer_append
    require_relative "../lib/ocran/zip_writer"

    with_tmpdir do
      # The smallest possible ZIP archive: an empty central directory.
      File.binwrite("archive.zip", ["PK\x05\x06", 0, 0, 0, 0, 0, 0, 0].pack("a4vvvvVVv"))
      File.write("source.txt", "from a file")

      entries = [
        Ocran::ZipWriter::Entry.new(name: "main.rb", data: "puts :hi\n" * 100),
        Ocran::ZipWriter::Entry.new(name: "app/deep/data.txt", source: "source.txt"),
      ]
      grew = Ocran::ZipWriter.append("archive.zip", entries)
      assert_operator grew, :>, 0

      members = read_zip_members("archive.zip")

      # Parent directories are synthesized so directory listings work.
      assert_equal ["main.rb", "app/", "app/deep/", "app/deep/data.txt"], members.keys
      assert_equal "puts :hi\n" * 100, members["main.rb"][:content]
      assert_equal "from a file", members["app/deep/data.txt"][:content]
      # Compressible content is deflated, and round-trips.
      assert_equal Ocran::ZipWriter::METHOD_DEFLATED, members["main.rb"][:method]

      # File type bits: regular files and directories, not bare permissions.
      assert_equal 0o100644, members["main.rb"][:mode]
      assert_equal 0o100644, members["app/deep/data.txt"][:mode]
      assert_equal 0o040755, members["app/"][:mode]

      # A second append must not disturb the first one.
      Ocran::ZipWriter.append("archive.zip", [Ocran::ZipWriter::Entry.new(name: "later.txt", data: "x")])
      again = read_zip_members("archive.zip")
      assert_equal "puts :hi\n" * 100, again["main.rb"][:content]
      assert_equal "x", again["later.txt"][:content]

      # Shadowing an existing member would silently override part of the
      # interpreter's own standard library.
      err = assert_raises(RuntimeError) do
        Ocran::ZipWriter.append("archive.zip", [Ocran::ZipWriter::Entry.new(name: "main.rb", data: "y")])
      end
      assert_match(/already contains an entry/, err.message)
    end
  end

  # Reads an archive back through its central directory - the way zipos
  # and every other reader finds members - and returns
  # name => { content:, method:, mode: }.
  def read_zip_members(path)
    require "zlib"

    data = File.binread(path)
    eocd = data.rindex("PK\x05\x06".b)
    _, _, _, _, total, cd_size, cd_offset, _ = data.byteslice(eocd, 22).unpack("a4vvvvVVv")
    central = data.byteslice(cd_offset, cd_size)

    members = {}
    pos = 0
    total.times do
      method, csize, size, name_length, extra_length, comment_length, external, offset =
        central.byteslice(pos, 46).unpack("x10vx8VVvvvx4VV")
      name = central.byteslice(pos + 46, name_length)
      pos += 46 + name_length + extra_length + comment_length

      local_name_length, local_extra_length = data.byteslice(offset, 30).unpack("x26vv")
      raw = data.byteslice(offset + 30 + local_name_length + local_extra_length, csize)
      content =
        if method == Ocran::ZipWriter::METHOD_DEFLATED
          Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw)
        else
          raw
        end
      assert_equal size, content.bytesize, "#{name} has a wrong uncompressed size"

      members[name] = { content: content, method: method, mode: external >> 16 }
    end
    members
  end

  # A cosmopolitan Ruby that runs an embedded /zip/main.rb, for the
  # compiler-free packaging tests. Returns nil when COSMO_RUBY is unset or
  # names a build without the hook.
  def find_cosmo_zip_ruby
    ruby = find_cosmo_ruby
    return nil unless ruby

    unless defined? Ocran::CosmoToolchain
      load File.expand_path("../lib/ocran/cosmo_toolchain.rb", __dir__)
    end
    Ocran::CosmoToolchain.zip_main_support?(ruby) ? ruby : nil
  end

  def cosmo_zip_prereqs
    skip "--cosmo-ruby requires a POSIX build host" if Gem.win_platform?
    ruby = find_cosmo_zip_ruby
    unless ruby
      skip "no cosmopolitan Ruby with /zip/main.rb support (set COSMO_RUBY to one)"
    end
    ruby
  end

  # End-to-end compiler-free build: --cosmo-ruby ALONE, no cosmocc
  # anywhere. The resulting .com must run a multi-file application from
  # inside its own ZIP store in an empty directory with an empty
  # environment - passing ARGV through, propagating the exit code, finding
  # a resource packed next to its sources AND a file next to the
  # executable - without creating a single temporary file.
  def test_cosmo_zip_end_to_end
    cosmo_ruby = cosmo_zip_prereqs

    with_fixture "cosmoruby_zip" do
      # COSMOCC deliberately points nowhere: this mode must not need it.
      assert_system({ "COSMOCC" => nil }, "ruby", ocran, "zipapp.rb", "data/message.txt",
                    *DefaultArgs, "--cosmo-ruby", cosmo_ruby)
      assert File.exist?("zipapp.com")
      assert_equal "MZqFpD", File.binread("zipapp.com", 6)

      # The interpreter is the executable, not a payload inside it: the
      # output is the interpreter plus the application, not twice the
      # interpreter.
      payload_size = File.size(cosmo_ruby)
      assert_operator File.size("zipapp.com"), :>=, payload_size
      assert_operator File.size("zipapp.com"), :<, payload_size * 3 / 2

      File.write("beside.txt", "next-to-exe\n")
      pristine_env "zipapp.com", "beside.txt" do
        tmp = Dir.mktmpdir("ocran-zip-tmp-")
        begin
          out = IO.popen([{ "TMPDIR" => tmp, "TMP" => tmp, "TEMP" => tmp },
                          "./zipapp.com", "alpha", "beta"], err: [:child, :out], &:read)
          assert $?.success?, "zipapp.com failed, output: #{out}"

          assert_match(/platform:x86_64-cosmo/, out)
          assert_match(/argv:\["alpha", "beta"\]/, out)
          # $0 is the packed script, so "if __FILE__ == $0" guards fire.
          assert_match(/main:true/, out)
          # The application runs from inside the archive, not from a
          # temporary directory - this is the visible behavior difference.
          assert_match(%r{dir:/zip/}, out)
          # A resource packed next to the sources, addressed via __dir__.
          assert_match(/packed:packed-resource/, out)
          # OCRAN_EXECUTABLE is the running .com, so files shipped next to
          # the executable are still reachable.
          assert_match(/executable:.*zipapp\.com/, out)
          assert_match(/beside:next-to-exe/, out)

          # Nothing is unpacked, so there is no extraction directory - the
          # thing the launcher stub creates on every start and leaks when
          # the process is killed. The only file that may appear is
          # Cosmopolitan's own ".ape-<version>" loader, a few kilobytes
          # written once per host by any APE on a kernel without binfmt
          # support.
          leftovers = Dir.children(tmp).reject { |name| name.start_with?(".ape") }
          assert_empty leftovers, "the ZIP packaging mode must not unpack anything at run time"
          directories = Dir.children(tmp).select { |name| File.directory?(File.join(tmp, name)) }
          assert_empty directories, "the ZIP packaging mode must not create an extraction directory"
        ensure
          FileUtils.rm_rf(tmp)
        end

        # Exit codes propagate, exactly - including on Windows, where the
        # interpreter used to hand the shell a POSIX wait status (code << 8).
        system({ "TMPDIR" => Dir.tmpdir }, "./zipapp.com", "fail", out: File::NULL)
        assert_equal 3, $?.exitstatus

        # The packed binary claims NONE of its command line, so an
        # application whose first argument is option-shaped - --version,
        # --help, -v, which is most of them - works like a native binary's.
        # No "--" dance, and no interpreter error message in place of the
        # app's own.
        leading = IO.popen(["./zipapp.com", "--fail", "-v", "--version"],
                           err: [:child, :out], &:read)
        assert_match(/argv:\["--fail", "-v", "--version"\]/, leading,
                     "option-shaped arguments must reach the application")
        refute_match(/invalid option/, leading,
                     "the interpreter must not parse the application's arguments")
        assert_equal 3, $?.exitstatus

        # "--" is no longer a separator either: it is just another argument.
        dashes = IO.popen(["./zipapp.com", "--", "--fail"], err: [:child, :out], &:read)
        assert_match(/argv:\["--", "--fail"\]/, dashes)

        # Interpreter options are still reachable, through the channel Ruby
        # already has for them.
        verbose = IO.popen([{ "RUBYOPT" => "-w" }, "./zipapp.com"],
                           err: [:child, :out], &:read)
        assert_match(/verbose:true/, verbose, "RUBYOPT must still reach the interpreter")
      end
    end
  end

  # A pure-Ruby gem packed for the ZIP mode must be activated by RubyGems
  # from inside the archive (GEM_HOME/GEM_PATH point at /zip, and the
  # generated main.rb makes RubyGems re-read them).
  def test_cosmo_zip_gem
    cosmo_ruby = cosmo_zip_prereqs
    begin
      Gem::Specification.find_by_name("mime-types")
    rescue Gem::LoadError
      skip "pure-Ruby test gem 'mime-types' is not installed on the build host"
    end

    with_fixture "cosmoruby_gem" do
      assert_system({ "COSMOCC" => nil }, "ruby", ocran, "gemapp.rb", *DefaultArgs,
                    "--cosmo-ruby", cosmo_ruby)
      assert File.exist?("gemapp.com")
      pristine_env "gemapp.com" do
        out = `env -i ./gemapp.com`
        assert $?.success?, "gemapp.com failed, output: #{out}"
        assert_match(/gem:txt/, out)
        assert_match(/platform:x86_64-cosmo/, out)
      end
    end
  end

  # Should be able to build executables with LZMA compression
  def test_lzma
    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", "--quiet", "--lzma")
      assert File.exist?(exe_name("helloworld"))
      pristine_env exe_name("helloworld") do
        assert_system(exe_name("helloworld"))
      end
    end
  end

  # Test that executables can writing a file to the current working
  # directory.
  def test_writefile
    with_fixture 'writefile' do
      assert_system("ruby", ocran, "writefile.rb", *DefaultArgs)
      assert File.exist?("output.txt") # Make sure ocran ran the script during build
      exe = exe_name("writefile")
      pristine_env exe do
        assert File.exist?(exe)
        assert_system(exe)
        assert File.exist?("output.txt")
        assert_equal "output", File.read("output.txt")
      end
    end
  end

  # With --no-dep-run, ocran should not run script during build
  def test_nodeprun
    with_fixture 'writefile' do
      assert_system("ruby", ocran, "writefile.rb", *(DefaultArgs + ["--no-dep-run"]))
      refute File.exist?("output.txt")
      exe = exe_name("writefile")
      pristine_env exe do
        assert File.exist?(exe)
        assert_system(exe)
        assert File.exist?("output.txt")
        assert_equal "output", File.read("output.txt")
      end
    end
  end

  # With dep run disabled but including all core libs, should be able
  # to use ruby standard libraries (i.e. cgi)
  def test_rubycoreincl
    with_fixture 'rubycoreincl' do
      assert_system("ruby", ocran, "rubycoreincl.rb", *(DefaultArgs + ["--no-dep-run", "--add-all-core"]))
      exe = exe_name("rubycoreincl")
      pristine_env exe do
        assert File.exist?(exe)
        assert_system(exe)
        assert File.exist?("output.txt")
        assert_equal "3 &lt; 5", File.read("output.txt")
      end
    end
  end

  # With dep run disabled but including corelibs and using a Bundler Gemfile, specified gems should
  # be automatically included and usable in packaged app
  def test_gemfile
    with_fixture 'bundlerusage' do
      assert_system("ruby", ocran, "bundlerusage.rb", "Gemfile", *(DefaultArgs + ["--no-dep-run", "--add-all-core", "--gemfile", "Gemfile", "--gem-all"]))
      exe = exe_name("bundlerusage")
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # A Gemfile that references a local development gem via a `path:` source
  # (or the `gemspec` directive) has its gemspec outside both the Ruby
  # installation and every gem path. The build must not abort; the gem is
  # packed into the bundled GEM_HOME and is usable in the packaged app
  # (github issue #34).
  #
  # Built with --no-autodll: on Ruby >= 3.5 fiddle is a bundled gem, so DLL
  # auto-detection cannot load fiddle/import under a Bundler context unless
  # the Gemfile lists fiddle. The fixture gem is pure Ruby and needs no
  # extra DLLs anyway.
  def test_gemfile_local_path_gem
    with_fixture 'localgem' do
      assert_system("ruby", ocran, "localgem.rb", *(DefaultArgs + ["--gemfile", "Gemfile", "--no-autodll"]))
      exe = exe_name("localgem")
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # With --debug-extract option, exe should unpack to local directory and leave it in place
  def test_debug_extract
    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--debug-extract"]))
      exe = exe_name("helloworld")
      pristine_env exe do
        assert_equal 0, Dir["ocr*"].size
        assert_system(exe)
        assert_equal 1, Dir["ocr*"].size
      end
    end
  end

  # Test that the --output option allows us to specify a different exe name
  def test_output_option
    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output", "goodbyeworld.exe"]))
      refute File.exist?(exe_name("helloworld"))
      assert File.exist?("goodbyeworld.exe")
    end
  end

  # Test that --output-dir produces a directory with the expected layout and
  # a working launch script.
  def test_output_dir
    with_fixture 'helloworld' do
      outdir = File.expand_path("helloworld_dir")
      assert_system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output-dir", outdir]))

      assert Dir.exist?(outdir),               "--output-dir did not create directory"
      assert Dir.exist?(File.join(outdir, "bin")), "bin/ missing from output directory"
      assert Dir.exist?(File.join(outdir, "src")), "src/ missing from output directory"

      launch_script = if Gem.win_platform?
                        File.join(outdir, "helloworld.bat")
                      else
                        File.join(outdir, "helloworld.sh")
                      end
      assert File.exist?(launch_script), "Launch script not found: #{launch_script}"

      # The wrapper executable is included by default and must run the app
      wrapper = File.join(outdir, exe_name("helloworld"))
      assert File.exist?(wrapper), "Wrapper executable not found: #{wrapper}"

      # The packed default gem dir must exist even if empty - RubyGems probes
      # it for writability at startup and warns when it is missing.
      default_gem_dir = Pathname(Gem.default_dir)
      exec_prefix = Pathname(RbConfig::CONFIG["exec_prefix"])
      begin
        rel = default_gem_dir.relative_path_from(exec_prefix).to_s
        unless rel.start_with?("..")
          assert Dir.exist?(File.join(outdir, rel)), "packed default gem dir missing: #{rel}"
        end
      rescue ArgumentError
        # default gem dir outside exec_prefix (e.g. some distro layouts) - not packed
      end

      Bundler.with_original_env do
        if Gem.win_platform?
          assert_system("cmd", "/c", launch_script)
        else
          assert_system("sh", launch_script)
        end
        assert_system(wrapper, message: "Wrapper executable failed to run")
      end
      # Running the wrapper must not delete the deployed directory
      assert File.exist?(launch_script)
    ensure
      FileUtils.rm_rf(outdir)
    end
  end

  # --no-wrapper-exe must omit the wrapper executable from directory output.
  def test_output_dir_no_wrapper_exe
    with_fixture 'helloworld' do
      outdir = File.expand_path("helloworld_dir")
      assert_system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output-dir", outdir, "--no-wrapper-exe"]))

      launch_script = File.join(outdir, Gem.win_platform? ? "helloworld.bat" : "helloworld.sh")
      assert File.exist?(launch_script), "Launch script not found: #{launch_script}"
      refute File.exist?(File.join(outdir, exe_name("helloworld"))), "Wrapper executable should be omitted with --no-wrapper-exe"
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
      assert_system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--output-zip", zip_path]))

      assert File.exist?(zip_path), "Zip file not created"
      assert File.size(zip_path) > 0, "Zip file is empty"

      Dir.mktmpdir(".ocrantest-zip-") do |tmpdir|
        if Gem.win_platform?
          assert_system("powershell", "-NoProfile", "-Command",
                        "Expand-Archive -Path '#{zip_path}' -DestinationPath '#{tmpdir}' -Force")
          launch_script = File.join(tmpdir, "helloworld.bat")
        else
          assert_system("unzip", "-q", zip_path, "-d", tmpdir)
          launch_script = File.join(tmpdir, "helloworld.sh")
        end

        assert File.exist?(launch_script), "Launch script missing from zip: #{launch_script}"
        assert Dir.exist?(File.join(tmpdir, "bin")), "bin/ missing from zip"
        assert Dir.exist?(File.join(tmpdir, "src")), "src/ missing from zip"

        Bundler.with_original_env do
          if Gem.win_platform?
            assert_system("cmd", "/c", launch_script)
          else
            assert_system("sh", launch_script)
          end
        end
      end
    end
  end

  # Test that we can specify a directory to be recursively included
  def test_directory_on_cmd_line
    with_fixture 'subdir' do
      assert_system("ruby", ocran, "subdir.rb", "a", *DefaultArgs)
      exe = exe_name("subdir")
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # Test that scripts can exit with a specific exit status code.
  def test_exitstatus
    with_fixture 'exitstatus' do
      assert_system("ruby", ocran, "exitstatus.rb", *DefaultArgs)
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
      assert_system("ruby", ocran, "arguments.rb", *DefaultArgs)
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
      assert_system("ruby", ocran, "arguments.rb", *args)
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
      assert_system("ruby", ocran, "arguments.rb", *args)
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
      assert_system("ruby", ocran, "buildarg.rb", *args)
      exe = exe_name("buildarg")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # Test that the standard output from a script can be redirected to a
  # file.
  def test_stdout_redir
    with_fixture 'stdoutredir' do
      assert_system("ruby", ocran, "stdoutredir.rb", *DefaultArgs)
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
      assert_system("ruby", ocran, "stdinredir.rb", *DefaultArgs)
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
      assert_system("ruby", ocran, "gdbmdll.rb", *args)
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
      assert_system("ruby", ocran, "relativerequire.rb", *DefaultArgs)
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
      assert_system("ruby", ocran, "autoload.rb", *DefaultArgs)
      exe = exe_name("autoload")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
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
        assert_system(exe)
      end
    end
  end

  # Test that Ocran picks up autoload statement nested in modules.
  def test_autoload_nested
    with_fixture 'autoloadnested' do
      assert_system("ruby", ocran, "autoloadnested.rb", *DefaultArgs)
      exe = exe_name("autoloadnested")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # Should find features via relative require paths, after script
  # changes to the right directory (Only valid for Ruby < 1.9.2).
  def test_relative_require_chdir_path
    with_fixture "relloadpath" do
      each_path_combo "bin/chdir1.rb" do |script|
        assert_system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('chdir1')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  # Should find features via relative require paths prefixed with
  # './', after script changes to the right directory.
  def test_relative_require_chdir_dotpath
    with_fixture "relloadpath" do
      each_path_combo "bin/chdir2.rb" do |script|
        assert_system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('chdir2')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
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
        assert_system('ruby', '-I', loadpaths[0], '-I', loadpaths[1], ocran, script, *DefaultArgs)
        exe = exe_name('external')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
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
          assert_system('ruby', ocran, script, *DefaultArgs)
        end
        exe = exe_name('external')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # dirname of script.
  def test_loadpath_mangling_dirname
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath0.rb" do |script|
        assert_system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('loadpath0')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # relative paths, and invoking from same directory.
  def test_loadpath_mangling_path
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath1.rb" do |script|
        assert_system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('loadpath1')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # relative paths with './'-prefix
  def test_loadpath_mangling_dotpath
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath2.rb" do |script|
        assert_system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('loadpath2')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  # Should pick up file when script modifies $LOAD_PATH by adding
  # absolute paths.
  def test_loadpath_mangling_abspath
    with_fixture 'relloadpath' do
      each_path_combo "bin/loadpath3.rb" do |script|
        assert_system('ruby', ocran, script, *DefaultArgs)
        exe = exe_name('loadpath3')
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
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
      assert_system("ruby", ocran, '--icon', icofile, "helloworld.rb", *DefaultArgs)
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # Test that additional non-script files can be added to the
  # executable and used by the script.
  def test_resource
    with_fixture 'resource' do
      assert_system("ruby", ocran, "resource.rb", "resource.txt", "res/resource.txt", *DefaultArgs)
      exe = exe_name("resource")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
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
        assert_system("ruby", ocran, "environment.rb", *DefaultArgs)
        exe = exe_name("environment")
        pristine_env exe do
          assert_system(exe)
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
        assert_system("ruby", ocran, "environment.rb", *test_args)
        exe = exe_name("environment")
        pristine_env exe do
          assert_system(exe)
          env = Marshal.load(File.open("environment.txt", "rb") { |f| f.read })
          assert_equal specified_rubyopt, env['RUBYOPT']
        end
      end
    end
  end

  def test_exit
    with_fixture 'exit' do
      assert_system("ruby", ocran, "exit.rb", *DefaultArgs)
      exe = exe_name("exit")
      pristine_env exe do
        assert File.exist?(exe)
        assert_system(exe)
      end
    end
  end

  def test_ocran_executable_env
    with_fixture 'environment' do
      assert_system("ruby", ocran, "environment.rb", *DefaultArgs)
      exe = exe_name("environment")
      pristine_env exe do
        assert_system(exe)
        env = Marshal.load(File.open("environment.txt", "rb") { |f| f.read })
        expected_path = Gem.win_platform? ? File.expand_path(exe).tr('/','\\') : File.expand_path(exe)
        assert_equal expected_path, env['OCRAN_EXECUTABLE']
      end
    end
  end

  def test_hierarchy
    with_fixture 'hierarchy' do
      assert_system("ruby", ocran, "hierarchy.rb", "assets/**/*", *DefaultArgs)
      exe = exe_name("hierarchy")
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  def test_temp_with_space
    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      tempdir = File.expand_path("temporary directory")
      mkdir_p tempdir
      exe = exe_name("helloworld")
      pristine_env exe do
        with_env "TMP" => tempdir.tr('/','\\') do
          assert_system(exe)
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
        assert_system("ruby", ocran, script_path, *DefaultArgs)
        exe = exe_name("helloworld")
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  def test_abspath_outside
    with_fixture "helloworld" do
      mkdir "build"
      cd "build" do
        assert_system("ruby", ocran, File.expand_path("../helloworld.rb"), *DefaultArgs)
        exe = exe_name("helloworld")
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  def test_relpath
    with_fixture "helloworld" do
      assert_system("ruby", ocran, "./helloworld.rb", *DefaultArgs)
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  def test_relpath_outside
    with_fixture "helloworld" do
      mkdir "build"
      cd "build" do
        assert_system("ruby", ocran, "../helloworld.rb", *DefaultArgs)
        exe = exe_name("helloworld")
        assert File.exist?(exe)
        pristine_env exe do
          assert_system(exe)
        end
      end
    end
  end

  # Should accept hierachical source code layout
  def test_srcroot
    with_fixture "srcroot" do
      assert_system("ruby", ocran, "bin/srcroot.rb", "share/data.txt", *DefaultArgs)
      exe = exe_name("srcroot")
      assert File.exist?(exe)
      pristine_env exe do
        exe_path = File.expand_path(exe)
        systemRoot = Gem.win_platform? ? ENV["SystemRoot"] : "/"
        cd systemRoot do
          assert_system(exe_path)
        end
      end
    end
  end

  # Should be able to build executables when script changes directory.
  def test_chdir
    with_fixture "chdir" do
      assert_system("ruby", ocran, "chdir.rb", *DefaultArgs)
      exe = exe_name("chdir")
      assert File.exist?(exe)
      pristine_env exe do
        exe_path = File.expand_path(exe)
        systemRoot = Gem.win_platform? ? ENV["SystemRoot"] : "/"
        cd systemRoot do
          assert_system(exe_path)
        end
      end
    end
  end

  # Test that the --chdir-first option changes directory before exe starts script
  def test_chdir_first
    with_fixture 'writefile' do
      # Control test; make sure the writefile script works as expected under default options
      assert_system("ruby", ocran, "writefile.rb", *(DefaultArgs))
      exe = exe_name("writefile")
      pristine_env exe do
        refute File.exist?("output.txt")
        assert_system(exe)
        assert File.exist?("output.txt")
      end

      assert_system("ruby", ocran, "writefile.rb", *(DefaultArgs + ["--chdir-first"]))
      pristine_env exe do
        refute File.exist?("output.txt")
        assert_system(exe)
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
      assert_system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      exe = exe_name("helloworld")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  def test_explicit_in_exec_prefix
    return unless File.directory?(RbConfig::CONFIG["exec_prefix"] + "/include")
    path = File.join(RbConfig::CONFIG["exec_prefix"], "include", "**", "*.h")
    number_of_files = Dir[path].size
    assert number_of_files > 3
    with_fixture "check_includes" do
      assert_system("ruby", ocran, "check_includes.rb", path, *DefaultArgs)
      exe = exe_name("check_includes")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe, number_of_files.to_s)
      end
    end
  end

  # Hello world test. Test that we can build and run executables.
  def test_nonexistent_temp
    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", *DefaultArgs)
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
      assert_system("where ISCC >NUL 2>&1", message: "ISCC not found in PATH; InnoSetup install step may have failed")
    else
      skip unless system("where ISCC >NUL 2>&1")
    end
    with_fixture 'innosetup' do
      icon_file = File.join(OcranRoot, 'src', 'vit-ruby.ico')
      assert_system("ruby", ocran, "innosetup.rb", '--icon', icon_file, "--quiet",
                    "--innosetup", "innosetup.iss", "--chdir-first", "--no-lzma",
                    "--output", "myapp.exe")
      assert File.exist?("Output/innosetup.exe")

      # Install silently and verify the wrapper executable is deployed to
      # {app} under the --output name and starts the application in place.
      target = File.expand_path("installed")
      assert_system("Output/innosetup.exe", "/VERYSILENT", "/SUPPRESSMSGBOXES",
                    "/NORESTART", "/DIR=#{target}", message: "silent install failed")
      wrapper = File.join(target, "myapp.exe")
      assert File.exist?(wrapper), "wrapper exe missing from installation"
      assert File.exist?(File.join(target, "launcher.bat"))
      Bundler.with_original_env do
        assert_system(wrapper, message: "installed wrapper exe failed to run")
      end
      # Running the wrapper must not delete the installation directory
      assert File.exist?(wrapper)
    end
  end

  # With --debug option
  def test_debug
    with_fixture 'helloworld' do
      assert_system("ruby", ocran, "helloworld.rb", *(DefaultArgs + ["--debug"]))
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
      assert_system("ruby", ocran, "helloworld.rb", *DefaultArgs)
      assert File.exist?(exe)

      multibyte_dir = "äあ💎"

      pristine_env exe do
        mkdir_p multibyte_dir
        cp exe, multibyte_dir
        Dir.chdir(multibyte_dir) do
          assert_system(exe)
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
      assert_system("ruby", ocran, script, *DefaultArgs)
      exe_name = script.sub(/\.rb$/, '')
      exe_name += '.exe' if Gem.win_platform?
      assert File.exist?(exe_name)
      pristine_env exe_name do
        assert_system(exe_name)
      end
    end
  end

  # Tests if a multibyte-named resource file is correctly included and read
  # at runtime after being packaged by OCRAN.
  def test_multibyte_resource_file
    with_fixture 'multibyte_file' do
      assert_system("ruby", ocran, "resource.rb", "äあ💎.txt", *DefaultArgs)
      exe = exe_name("resource")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
      end
    end
  end

  # Tests that OCRAN can handle resource files stored in a directory
  # with multibyte (UTF-8) characters in its name.
  def test_multibyte_resource_dir
    with_fixture 'multibyte_dir' do
      assert_system("ruby", ocran, "resource.rb", "äあ💎/äあ💎.txt", *DefaultArgs)
      assert File.exist?(exe_name("resource"))
      pristine_env exe_name("resource") do
        assert_system(exe_name("resource"))
      end
    end
  end

  # Test that code-signed executables still work
  def test_codesigning_support
    skip "Only for windows" unless Gem.win_platform?
    with_fixture 'helloworld' do
      each_path_combo "helloworld.rb" do |script|
        assert_system("ruby", ocran, script, *DefaultArgs)
        FakeCodeSigner.new(input_file: "helloworld.exe",
                           output_file: "helloworld-signed.exe",
                           padding: rand(20)).sign

        pristine_env "helloworld.exe", "helloworld-signed.exe" do
          assert_system("helloworld.exe")
          assert_system("helloworld-signed.exe")
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
      assert_system("ruby", ocran, "tk.rb", *DefaultArgs)
      exe = exe_name("tk")
      assert File.exist?(exe)
      pristine_env exe do
         assert_system(exe)
         puts "sucessfully tested tk" if $?.success?
      end
    end
  end

  # Regression test: FXRuby (fox16) ships native extension DLLs that must be
  # bundled by OCRAN. Without them the packaged exe raises a LoadError for
  # fox16 at runtime even though the build step succeeds. The fixture exits
  # immediately so we can verify a clean load without needing a display.
  def test_fxruby
    skip "fxruby gem not available" unless Gem::Specification.find_all_by_name("fxruby").any?
    with_fixture "fxruby" do
      assert_system("ruby", ocran, "fxruby.rb", *DefaultArgs)
      exe = exe_name("fxruby")
      assert File.exist?(exe)
      pristine_env exe do
        assert_system(exe)
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
      assert_system("ruby", ocran, "glimmer_libui.rb", *DefaultArgs)
      assert File.exist?(exe_name("glimmer_libui"))
      pristine_env exe_name("glimmer_libui") do
        assert_system(exe_name("glimmer_libui"))
      end
    end
  end

  # Regression test: zlib.so has a companion zlib.so-assembly.manifest and
  # zlib1.dll in archdir. Without them the SxS activation context fails with
  # error 14001 at runtime. Verifies that compress/decompress round-trips work.
  def test_zlib
    with_fixture 'zlib' do
      assert_system("ruby", ocran, "zlib.rb", *DefaultArgs)
      assert File.exist?(exe_name("zlib"))
      pristine_env exe_name("zlib") do
        assert_system(exe_name("zlib"))
      end
    end
  end

  # Tests that a script using net/http HTTPS works correctly when packaged and
  # that OCRAN bundles the SSL certificate into the extraction directory.
  # OCRAN automatically sets SSL_CERT_FILE to the extracted cert path, so the
  # fixture writes the effective cert path to cert_path.txt for verification.
  def test_openssl_https
    with_fixture 'openssl_https' do
      assert_system("ruby", ocran, "openssl_https.rb", *DefaultArgs)
      assert File.exist?(exe_name("openssl_https"))
      pristine_env exe_name("openssl_https") do
        assert_system(exe_name("openssl_https"))
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
      assert_system("ruby", ocran, "openssl_https_cacert.rb", *DefaultArgs)
      exe = exe_name("openssl_https_cacert")
      assert File.exist?(exe)

      pristine_env exe, "cacert.pem" do
        assert_system(exe)
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
      assert_system("ruby", ocran, "helloworld.rb", "--macosx-bundle", *DefaultArgs)

      bundle = "helloworld.app"
      assert Dir.exist?(bundle), "Expected #{bundle} directory to exist"
      assert File.exist?(File.join(bundle, "Contents", "Info.plist")), "Expected Info.plist"

      exe = File.join(bundle, "Contents", "MacOS", "helloworld")
      assert File.exist?(exe), "Expected executable at Contents/MacOS/helloworld"
      assert File.executable?(exe), "Expected Contents/MacOS/helloworld to be executable"

      pristine_env exe do
        assert_system(File.basename(exe))
      end
    end
  end

  # Tests --macosx-bundle with a custom name, bundle-id, and icon.
  def test_macosx_bundle_custom
    skip "macOS app bundle test is macOS-only" unless RUBY_PLATFORM.include?("darwin")
    with_fixture 'helloworld' do
      # Create a minimal placeholder .icns file (not a real icon, just tests the copy)
      File.write("test.icns", "placeholder")

      assert_system("ruby", ocran, "helloworld.rb",
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

  # The RUN_IN_EXE_DIR wrapper stub runs the application directly from the
  # directory the executable resides in - no extraction directory is created
  # and the application directory must never be deleted on exit.
  # This is the wrapper used for Inno Setup builds (pre-1.4/OCRA behavior).
  def test_run_in_exe_dir_stub
    require_relative "../lib/ocran/stub_builder"
    require_relative "../lib/ocran/build_constants"
    with_tmpdir do
      appdir = File.expand_path("app")
      mkdir_p File.join(appdir, "bin")
      mkdir_p File.join(appdir, "src")
      ruby_name = File.basename(RbConfig.ruby)
      cp RbConfig.ruby, File.join(appdir, "bin", ruby_name)
      if Gem.win_platform?
        # ruby.exe needs its DLLs next to it at runtime
        rubydir = File.dirname(RbConfig.ruby)
        Dir.glob(File.join(rubydir, "*.dll")).each do |dll|
          cp dll, File.join(appdir, "bin", File.basename(dll))
        end
        builtin = File.join(rubydir, "ruby_builtin_dlls")
        cp_r builtin, File.join(appdir, "bin", "ruby_builtin_dlls") if Dir.exist?(builtin)
      end
      File.write(File.join(appdir, "src", "check.rb"), <<~RUBY)
        File.write(File.join(__dir__, "..", "result.txt"), ENV["OCRAN_TEST_VAR"].to_s)
      RUBY

      wrapper = Pathname(appdir) / exe_name("wrapper")
      Ocran::StubBuilder.new(wrapper, run_in_exe_dir: true) do |stub|
        stub.export("OCRAN_TEST_VAR", File.join(Ocran::BuildConstants::EXTRACT_ROOT, "src"))
        stub.exec(Pathname("bin") / ruby_name, Pathname("src") / "check.rb")
      end

      assert File.exist?(wrapper)
      assert_system(wrapper.to_s)

      # The placeholder must resolve to the executable's own directory.
      # The stub reports native separators on Windows - compare normalized.
      assert_equal File.join(appdir, "src").tr("\\", "/"),
                   File.read(File.join(appdir, "result.txt")).tr("\\", "/")
      # The application directory must survive (no auto-clean, no extraction)
      assert File.exist?(File.join(appdir, "src", "check.rb"))
      assert File.exist?(File.join(appdir, "bin", ruby_name))
    end
  end

  # Inno Setup builds must produce a wrapper executable named like --output
  # and install it into {app}, so that user ISS scripts can reference it
  # (e.g. [Run]/[UninstallRun] entries, Windows service registration).
  # Uses a fake ISCC so the pipeline also runs where InnoSetup is missing.
  def test_innosetup_wrapper_exe
    # On Windows a real ISCC.exe on the runners wins over a fake ISCC.bat in
    # PATH resolution; the full scenario is covered there by test_innosetup.
    skip "fake ISCC is not reliable on Windows" if Gem.win_platform?
    with_fixture 'innosetup' do
      fakebin = File.expand_path("fakebin")
      mkdir_p fakebin
      fake_iscc = File.join(fakebin, "ISCC")
      File.write(fake_iscc, "#!/bin/sh\nfor a; do last=$a; done\ncp \"$last\" saved.iss\n")
      File.chmod(0755, fake_iscc)

      orig_path = ENV["PATH"]
      begin
        ENV["PATH"] = fakebin + File::PATH_SEPARATOR + orig_path
        assert_system("ruby", ocran, "innosetup.rb", "--quiet", "--no-lzma",
                      "--chdir-first", "--innosetup", "innosetup.iss",
                      "--output", "myapp.exe")
      ensure
        ENV["PATH"] = orig_path
      end

      assert File.exist?("saved.iss"), "fake ISCC was not invoked"
      iss = File.read("saved.iss")
      # Wrapper executable installed to {app} under the --output name
      assert_match(/^Source: "[^"]*myapp\.exe"; DestDir: "\{app\}(\/\.)?";/, iss)
      # The launcher batch file is still part of the installation
      assert_match(/launcher\.bat/, iss)

      # With --no-wrapper-exe the wrapper must be omitted from the installer
      rm "saved.iss"
      orig_path = ENV["PATH"]
      begin
        ENV["PATH"] = fakebin + File::PATH_SEPARATOR + orig_path
        assert_system("ruby", ocran, "innosetup.rb", "--quiet", "--no-lzma",
                      "--chdir-first", "--innosetup", "innosetup.iss",
                      "--output", "myapp.exe", "--no-wrapper-exe")
      ensure
        ENV["PATH"] = orig_path
      end
      iss = File.read("saved.iss")
      refute_match(/myapp\.exe/, iss)
      assert_match(/launcher\.bat/, iss)
    end
  end

  # Default gems (e.g. fiddle, singleton on Homebrew or distro-packaged Ruby)
  # have a gemspec but no materialized gem directory. Collecting gem files
  # must not raise Errno::ENOENT for them (github issue #44).
  def test_gem_files_with_missing_gem_dir
    require_relative "../lib/ocran/gem_spec_queryable"

    spec = Gem::Specification.new do |s|
      s.name = "ocran_phantom_default_gem"
      s.version = "1.0.0"
    end
    spec.extend(Ocran::GemSpecQueryable)

    refute File.directory?(spec.gem_dir)
    assert_equal [], spec.find_gem_files([:files, :scripts, :extras], [])
  end
end
