# frozen_string_literal: true
require "pathname"

module Ocran
  class Option
    load File.expand_path("refine_pathname.rb", __dir__) unless defined? RefinePathname
    using RefinePathname

    def initialize
      @options = {
        :add_all_core? => false,
        :add_all_encoding? => true,
        :argv => [],
        :auto_detect_dlls? => true,
        :bundle_identifier => nil,
        :macosx_bundle => nil,
        :macosx_bundle? => false,
        :chdir_before? => false,
        :chdir_exe_dir? => false,
        :cosmo_cc => nil,
        :cosmo_ruby => nil,
        :cosmo_zip? => false,
        :enable_compression? => true,
        :enable_debug_extract? => false,
        :enable_debug_mode? => false,
        :extra_dlls => [],
        :force_console? => false,
        :force_windows? => false,
        :gem_options => [],
        :gemfile => nil,
        :icon_filename => nil,
        :inno_setup_script => nil,
        :load_autoload? => true,
        :output_dir => nil,
        :output_override => nil,
        :output_zip => nil,
        :quiet? => false,
        :rubyopt => nil,
        :run_script? => true,
        :script => nil,
        :source_files => [],
        :verbose? => false,
        :warning? => true,
        :wrapper_exe? => true,
      }
    end

    def usage
      <<EOF
ocran [options] script.rb

Ocran options:

--help, -h         Display this information.
--quiet            Suppress output while building executable.
--verbose          Show extra output while building executable.
--version          Display version number and exit.

Packaging options:

--dll dllname      Include additional DLLs from the Ruby bindir.
--add-all-core     Add all core ruby libraries to the executable.
--gemfile <file>   Add all gems and dependencies listed in a Bundler Gemfile.
--no-enc           Exclude encoding support files

Gem content detection modes:

--gem-minimal[=gem1,..]  Include only loaded scripts
--gem-guess=[gem1,...]   Include loaded scripts & best guess (DEFAULT)
--gem-all[=gem1,..]      Include all scripts & files
--gem-full[=gem1,..]     Include EVERYTHING
--gem-spec[=gem1,..]     Include files in gemspec (Does not work with Rubygems 1.7+)

  minimal: loaded scripts
  guess: loaded scripts and other files
  all: loaded scripts, other scripts, other files (except extras)
  full: Everything found in the gem directory

--[no-]gem-scripts[=..]  Other script files than those loaded
--[no-]gem-files[=..]    Other files (e.g. data files)
--[no-]gem-extras[=..]   Extra files (README, etc.)

  scripts: .rb/.rbw files
  extras: C/C++ sources, object files, test, spec, README
  files: all other files

Auto-detection options:

--no-dep-run       Don't run script.rb to check for dependencies.
--no-autoload      Don't load/include script.rb's autoloads.
--no-autodll       Disable detection of runtime DLL dependencies.

Output options:

--output <file>    Name the exe to generate. Defaults to ./<scriptname>.exe.
--output-dir <dir> Output all files to a directory with a launch script instead of an exe.
--output-zip <file> Output a zip archive containing all files and a launch script.
--no-wrapper-exe   Do not add the wrapper executable to installer, directory or
                   zip output (a launch script is always included there).
--macosx-bundle    Build a macOS .app bundle. Use --output to name it (default: <scriptname>.app).
--bundle-id <id>   Bundle identifier for the macOS app bundle (default: com.example.<appname>).
--no-lzma          Disable LZMA compression of the executable.
--innosetup <file> Use given Inno Setup script (.iss) to create an installer.

Executable options:

--windows          Force Windows application (rubyw.exe)
--console          Force console application (ruby.exe)
--chdir-first      When exe starts, change working directory to app dir.
--chdir-exe-dir    When exe starts, change working directory to the directory
                   containing the executable itself.
--icon <ico>       Replace icon with a custom one.
--rubyopt <str>    Set the RUBYOPT environment variable when running the executable.
                   -I/-r entries with absolute build-machine paths are
                   translated to their packed locations at build time.
--debug            Executable will be verbose.
--debug-extract    Executable will unpack to local dir and not delete after.

Experimental options:

--cosmo-ruby <ruby.com>  Package the given cosmopolitan-built Ruby (an APE,
                   e.g. ruby.com) as the interpreter instead of the host
                   Ruby: the result is a single <scriptname>.com that runs
                   on Linux, Windows and macOS. The APE must be fully
                   self-contained (stdlib embedded in its ZIP store).
                   Dependency detection still runs under the host Ruby;
                   native-extension gems are rejected (pure-Ruby gems are
                   packed as usual).
                   When the given interpreter runs an embedded /zip/main.rb
                   (CosmoRuby builds do), the application is injected into
                   its ZIP store: no compiler is needed and the executable
                   starts without unpacking anything. Otherwise OCRAN falls
                   back to an APE launcher stub that extracts the
                   application at every start, and locates the cosmocc
                   toolchain to build that stub automatically (COSMOCC
                   environment variable, cosmocc in PATH, then conventional
                   install locations such as ~/.cosmocc/*/bin/cosmocc).
--cosmo <path>     Use the Cosmopolitan toolchain (cosmocc) at <path> to
                   build the launcher stub, overriding the automatic
                   toolchain lookup. <path> is the cosmocc executable or
                   its install dir. Given together with --cosmo-ruby it
                   forces the launcher-stub build even when the interpreter
                   supports ZIP packaging. Given without --cosmo-ruby, it
                   packages the host Ruby behind an APE stub. Console-only;
                   output defaults to <scriptname>.com.
                   (Alias: --cosmo-toolchain)
EOF
    end

    # Pulls in Ocran::CosmoToolchain for the --cosmo/--cosmo-ruby options.
    #
    # Deliberately Kernel#load and not require_relative: OCRAN detects the
    # application's dependencies by diffing $LOADED_FEATURES around the
    # dependency run, and the "before" snapshot is taken *before* the command
    # line is parsed (Runner#initialize). Anything require'd from here would
    # therefore show up in that diff and be packed into the user's
    # application - packing OCRAN's own source file with it, and (because the
    # src prefix is the common parent of all source files) moving the whole
    # application down into a deeper src/ subdirectory. Kernel#load leaves
    # $LOADED_FEATURES untouched; the same idiom is used for
    # refine_pathname.rb above.
    def load_cosmo_toolchain
      load File.expand_path("cosmo_toolchain.rb", __dir__) unless defined? CosmoToolchain
    end

    def parse(argv)
      while (arg = argv.shift)
        case arg
        when /\A--(no-)?lzma\z/
          @options[:enable_compression?] = !$1
        when "--no-dep-run"
          @options[:run_script?] = false
        when "--add-all-core"
          @options[:add_all_core?] = true
        when "--output"
          path = argv.shift
          @options[:output_override] = Pathname.new(path).expand_path if path
        when "--output-dir"
          path = argv.shift
          @options[:output_dir] = Pathname.new(path).expand_path if path
        when "--output-zip"
          path = argv.shift
          @options[:output_zip] = Pathname.new(path).expand_path if path
        when "--no-wrapper-exe"
          @options[:wrapper_exe?] = false
        when "--macosx-bundle"
          @options[:macosx_bundle?] = true
        when "--bundle-id"
          @options[:bundle_identifier] = argv.shift
        when "--dll"
          path = argv.shift
          @options[:extra_dlls] << path if path
        when "--quiet"
          @options[:quiet?] = true
        when "--verbose"
          @options[:verbose?] = true
        when "--windows"
          @options[:force_windows?] = true
        when "--console"
          @options[:force_console?] = true
        when "--no-autoload"
          @options[:load_autoload?] = false
        when "--chdir-first"
          @options[:chdir_before?] = true
        when "--chdir-exe-dir"
          @options[:chdir_exe_dir?] = true
        when "--icon"
          path = argv.shift
          raise "Icon file #{path} not found" unless path && File.exist?(path)
          @options[:icon_filename] = Pathname.new(path).expand_path
        when "--rubyopt"
          @options[:rubyopt] = argv.shift
        when "--cosmo", "--cosmo-toolchain"
          # Kept unresolved until validation: resolving here would report
          # "cosmocc ... is not executable" on a Windows build host, ahead of
          # the clearer "not supported when building on Windows" check.
          @options[:cosmo_cc] = argv.shift
        when "--cosmo-ruby"
          load_cosmo_toolchain
          @options[:cosmo_ruby] = CosmoToolchain.resolve_ruby(argv.shift)
        when "--gemfile"
          path = argv.shift
          raise "Gemfile #{path} not found" unless path && File.exist?(path)
          @options[:gemfile] = Pathname.new(path).expand_path
        when "--innosetup"
          path = argv.shift
          raise "Inno Script #{path} not found" unless path && File.exist?(path)
          @options[:inno_setup_script] = Pathname.new(path).expand_path
        when "--no-autodll"
          @options[:auto_detect_dlls?] = false
        when "--version"
          require_relative "version"
          puts "Ocran #{VERSION}"
          raise SystemExit
        when "--no-warnings"
          @options[:warning?] = false
        when "--debug"
          @options[:enable_debug_mode?] = true
        when "--debug-extract"
          @options[:enable_debug_extract?] = true
        when "--"
          @options[:argv] = argv.dup
          argv.clear
          break
        when /\A--(no-)?enc\z/
          @options[:add_all_encoding?] = !$1
        when /\A--(no-)?gem-(\w+)(?:=(.*))?$/
          negate, group, list = $1, $2, $3
          @options[:gem_options] << [negate, group.to_sym, list&.split(",")] if group
        when "--help", "-h", /\A--./
          puts usage
          raise SystemExit
        else
          expanded = Dir.glob(arg)
          if expanded.empty?
            raise "#{arg} not found!" unless File.exist?(arg)
            expanded = [arg]
          end

          expanded.each do |f|
            if File.directory?(f)
              raise "#{f} is empty!" if Dir.empty?(f)
              # If a directory is passed, we want all files under that directory
              @options[:source_files] += Pathname.new(f).find.reject(&:directory?).map(&:expand_path)
            else
              @options[:source_files] << Pathname.new(f).expand_path
            end
          end
        end
      end

      raise "No script file specified" if source_files.empty?

      @options[:script] = source_files.first

      @options[:force_autoload?] = run_script? && load_autoload?

      @options[:output_executable] =
        if output_override
          output_override
        else
          executable = script
          # If debug mode is enabled, append "-debug" to the filename
          executable = executable.append_to_filename("-debug") if enable_debug_mode?
          # Build output files are created in the current directory.
          # APE binaries built with cosmocc conventionally use .com.
          ext = if cosmo?
                  ".com"
                elsif Gem.win_platform?
                  ".exe"
                else
                  ""
                end
          executable.basename.sub_ext(ext).expand_path
        end

      if @options[:macosx_bundle?]
        bundle_base = output_override || script.basename
        @options[:macosx_bundle] = Pathname(bundle_base).sub_ext(".app").expand_path
      end

      if chdir_before? && chdir_exe_dir?
        raise "--chdir-first and --chdir-exe-dir cannot be used together"
      end

      @options[:use_inno_setup?] = !!inno_setup_script

      @options[:verbose?] &&= !quiet?

      @options[:windowed?] = (script.extname?(".rbw") || force_windows?) && !force_console?

      if inno_setup_script
        if enable_debug_extract?
          raise "The --debug-extract option conflicts with use of Inno Setup"
        end

        if enable_compression?
          raise "LZMA compression must be disabled (--no-lzma) when using Inno Setup"
        end

        unless chdir_before?
          raise "Chdir-first mode must be enabled (--chdir-first) when using Inno Setup"
        end
      end

      if output_dir && output_zip
        raise "--output-dir and --output-zip cannot be used together"
      end

      if cosmo?
        opt = cosmo_cc ? "--cosmo" : "--cosmo-ruby"

        if Gem.win_platform?
          raise "#{opt} is not supported when building on Windows (build the APE package on a Linux/macOS host)"
        end

        if force_windows?
          raise "--windows cannot be used with #{opt}: cosmocc has no GUI (stubw) equivalent; APE stubs are console-only"
        end

        load_cosmo_toolchain

        # A cosmopolitan Ruby that runs an embedded /zip/main.rb can carry
        # the application inside its own ZIP store, which needs no compiler
        # and no launcher stub at all - so that is what --cosmo-ruby does
        # on its own. Naming a toolchain with --cosmo is the way to ask for
        # the launcher stub explicitly; the other output formats
        # (--output-dir, --output-zip, --innosetup, --macosx-bundle) are
        # directory layouts rather than a single binary, so they keep using
        # it too.
        @options[:cosmo_zip?] =
          !!cosmo_ruby && !cosmo_cc && !single_binary_output_conflict &&
          CosmoToolchain.zip_main_support?(cosmo_ruby)

        unless cosmo_zip?
          # The APE stub is compiled with cosmocc. --cosmo names that
          # toolchain explicitly; otherwise it is discovered on the build
          # host (COSMOCC, PATH, conventional install locations), so one
          # option is still enough. Resolved here, before the dependency
          # run, so a missing toolchain fails fast.
          @options[:cosmo_cc] = CosmoToolchain.require_cc(cosmo_cc)
        end
      end

      if macosx_bundle && (output_dir || output_zip || inno_setup_script)
        raise "--macosx-bundle cannot be combined with --output-dir, --output-zip, or --innosetup"
      end
    end

    def add_all_core? = @options[__method__]

    def add_all_encoding? = @options[__method__]

    def argv = @options[__method__]

    def bundle_identifier = @options[__method__]

    def macosx_bundle = @options[__method__]

    def auto_detect_dlls? = @options[__method__]

    def chdir_before? = @options[__method__]

    def chdir_exe_dir? = @options[__method__]
    def cosmo_cc = @options[__method__]

    def cosmo_ruby = @options[__method__]

    # True when the application is packaged by injecting it into the ZIP
    # store of the cosmopolitan Ruby itself: no cosmocc, no launcher stub,
    # and no extraction to a temporary directory at run time.
    def cosmo_zip? = @options[__method__]

    # Output formats that are not a single self-contained binary, and
    # therefore cannot be produced by injecting into the interpreter.
    def single_binary_output_conflict
      output_dir || output_zip || inno_setup_script || @options[:macosx_bundle?]
    end
    private :single_binary_output_conflict

    # True when the build produces an APE (Actually Portable Executable),
    # i.e. an APE launcher stub is used: an explicit toolchain (--cosmo), a
    # cosmopolitan Ruby payload (--cosmo-ruby, whose toolchain is inferred),
    # or both.
    def cosmo? = !!(cosmo_cc || cosmo_ruby)

    def enable_compression? = @options[__method__]

    def enable_debug_extract? = @options[__method__]

    def enable_debug_mode? = @options[__method__]

    def extra_dlls = @options[__method__]

    def force_autoload? = @options[__method__]

    def force_console? = @options[__method__]

    def force_windows? = @options[__method__]

    def gem_options = @options[__method__]

    def gemfile = @options[__method__]

    def icon_filename = @options[__method__]

    def inno_setup_script = @options[__method__]

    def load_autoload? = @options[__method__]

    def output_dir = @options[__method__]

    def output_executable = @options[__method__]

    def output_override = @options[__method__]

    def output_zip = @options[__method__]

    def quiet? = @options[__method__]

    def wrapper_exe? = @options[__method__]

    def rubyopt = @options[__method__]

    def run_script? = @options[__method__]

    def script = @options[__method__]

    # The names Bundler accepts for a Gemfile, most common first.
    GEMFILE_NAMES = %w[Gemfile gems.rb].freeze
    private_constant :GEMFILE_NAMES

    # The Gemfile the application runs under: the one named by --gemfile,
    # or else the nearest Gemfile at or above the script's directory, which
    # is where Bundler itself would look. Returns nil when the application
    # has no Gemfile at all.
    #
    # This is how the application's own bundle is told apart from whatever
    # bundle OCRAN happens to have been started under. Running
    # `bundle exec ocran app.rb` from the application's own directory is the
    # ordinary case, and there the two are the same file; packaging some
    # other project from inside this one's bundle is not.
    def application_gemfile
      return gemfile if gemfile

      dir = script.expand_path.dirname
      loop do
        GEMFILE_NAMES.each do |name|
          candidate = dir + name
          return candidate if candidate.file?
        end
        parent = dir.parent
        return nil if parent == dir

        dir = parent
      end
    end

    def source_files = @options[__method__]

    def use_inno_setup? = @options[__method__]

    def verbose? = @options[__method__]

    def warning? = @options[__method__]

    def windowed?
      return false unless Gem.win_platform?
      @options[:windowed?]
    end
  end
end
