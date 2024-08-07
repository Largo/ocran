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
        :chdir_before? => false,
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
        :output_override => nil,
        :quiet? => false,
        :rubyopt => nil,
        :run_script? => true,
        :script => nil,
        :source_files => [],
        :verbose? => false,
        :warning? => true,
      }
    end

    def usage
      <<EOF
ocran [options] script.rb

Ocran options:

--help             Display this information.
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
--no-lzma          Disable LZMA compression of the executable.
--innosetup <file> Use given Inno Setup script (.iss) to create an installer.

Executable options:

--windows          Force Windows application (rubyw.exe)
--console          Force console application (ruby.exe)
--chdir-first      When exe starts, change working directory to app dir.
--icon <ico>       Replace icon with a custom one.
--rubyopt <str>    Set the RUBYOPT environment variable when running the executable
--debug            Executable will be verbose.
--debug-extract    Executable will unpack to local dir and not delete after.
EOF
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
        when "--icon"
          path = argv.shift
          raise "Icon file #{path} not found" unless path && File.exist?(path)
          @options[:icon_filename] = Pathname.new(path).expand_path
        when "--rubyopt"
          @options[:rubyopt] = argv.shift
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
        when "--help", /\A--./
          puts usage
          raise SystemExit
        else
          raise "#{arg} not found!" unless File.exist?(arg)

          if File.directory?(arg)
            raise "#{arg} is empty!" if Dir.empty?(arg)
            # If a directory is passed, we want all files under that directory
            @options[:source_files] += Pathname.new(arg).find.reject(&:directory?).map(&:expand_path)
          else
            @options[:source_files] << Pathname.new(arg).expand_path
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
          # Build output files are created in the current directory
          executable.basename.sub_ext(".exe").expand_path
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
    end

    def add_all_core? = @options[__method__]

    def add_all_encoding? = @options[__method__]

    def argv = @options[__method__]

    def auto_detect_dlls? = @options[__method__]

    def chdir_before? = @options[__method__]

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

    def output_executable = @options[__method__]

    def output_override = @options[__method__]

    def quiet? = @options[__method__]

    def rubyopt = @options[__method__]

    def run_script? = @options[__method__]

    def script = @options[__method__]

    def source_files = @options[__method__]

    def use_inno_setup? = @options[__method__]

    def verbose? = @options[__method__]

    def warning? = @options[__method__]

    def windowed? = @options[__method__]
  end
end
