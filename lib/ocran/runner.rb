# frozen_string_literal: true
load File.expand_path("../ocran.rb", __dir__)

module Ocran
  class Runner
    load File.expand_path("command_output.rb", __dir__)
    include CommandOutput

    def fatal_error(statement)
      error statement
      exit false
    end

    def initialize
      load File.expand_path("runtime_environment.rb", __dir__)
      @pre_env = RuntimeEnvironment.save

      load File.expand_path("option.rb", __dir__)
      @option = Option.new.tap do |opt|
        opt.parse(ARGV)
      rescue RuntimeError => e
        # Capture RuntimeError during parsing and display an appropriate
        # error message to the user. This error usually occurs from invalid
        # option arguments.
        fatal_error e.message
      else
        # Update ARGV with the parsed command line arguments to pass to
        # the user's script. This ensures the script executes based on
        # the user-specified arguments.
        ARGV.replace(opt.argv)
      end

      Ocran.option = @option

      @ignore_modules = ObjectSpace.each_object(Module).to_a
    end

    def run
      at_exit do
        if $!.nil? or $!.kind_of?(SystemExit)
          build
          exit
        end
      end

      exit unless @option.run_script?
      apply_gemfile_to_bundler_env if @option.gemfile
      say "Loading script to check dependencies"
      $PROGRAM_NAME = @option.script.to_s
    end

    # --gemfile names the Gemfile the application runs under, so it has to
    # govern the dependency run as well, not just the later Gemfile scan.
    # The script is loaded in this very process, and a BUNDLE_GEMFILE
    # inherited from the environment would otherwise win: invoke OCRAN from
    # inside another project's `bundle exec` and the script's
    # `require "bundler/setup"` sets up that project's bundle instead of the
    # application's. Gems only the application's Gemfile provides are then
    # missing, and local development gems declared with `path:` or `gemspec`
    # always are, since they exist nowhere else. The dependency run dies with
    # a LoadError before anything can be packed (github issue #34).
    def apply_gemfile_to_bundler_env
      gemfile = @option.gemfile.to_s
      active = active_bundler_gemfile

      ENV["BUNDLE_GEMFILE"] = gemfile
      return if active.nil? || same_file?(active, gemfile)

      # Past this point the ambient bundle is a different one, so anything
      # else describing it has to go: BUNDLE_LOCKFILE names the lockfile of
      # the bundle being displaced, and Bundler would sooner believe it than
      # the Gemfile we just pointed it at.
      ENV.delete("BUNDLE_LOCKFILE")
      return unless defined?(Bundler) && Bundler.respond_to?(:reset!)

      # `bundle exec` puts -rbundler/setup in RUBYOPT as well, so the wrong
      # bundle may already be set up by the time this runs. The variable
      # alone is then too late: bundler/setup sits in $LOADED_FEATURES, and
      # the script's own `require "bundler/setup"` would be a no-op. Drop
      # Bundler's memoized state and let it be set up afresh, against the
      # Gemfile we were given.
      verbose "Rebinding Bundler from #{active} to #{gemfile}"
      Bundler.reset!
      $LOADED_FEATURES.delete_if { |feature| feature.match?(%r{[\\/]bundler[\\/]setup\.rb\z}) }
    end

    # The Gemfile this process was started against, if any.
    def active_bundler_gemfile
      return ENV["BUNDLE_GEMFILE"] unless ENV["BUNDLE_GEMFILE"].to_s.empty?
      return nil unless defined?(Bundler) && Bundler.respond_to?(:default_gemfile)

      Bundler.default_gemfile.to_s
    rescue StandardError
      # Bundler raises when there is no Gemfile anywhere above the working
      # directory, which just means there is no ambient bundle to displace.
      nil
    end

    def same_file?(a, b)
      File.identical?(a, b) || File.expand_path(a) == File.expand_path(b)
    end

    # Force loading autoloaded constants. Searches through all modules
    # (and hence classes), and checks their constants for autoloaded
    # ones, then attempts to load them.
    def attempt_load_autoload(ignore_modules = [])
      checked_modules = ignore_modules.inject({}) { |h, mod| h[mod] = true; h }
      while ObjectSpace.each_object(Module).count { |mod|
        next if checked_modules.include?(mod)
        mod.constants.each do |const|
          next unless mod.autoload?(const)
          say "Attempting to trigger autoload of #{mod}::#{const}"
          begin
            mod.const_get(const)
          rescue ScriptError, StandardError => e
            # Some autoload constants may throw exceptions beyond the expected
            # errors. This includes issues dependent on the system or execution
            # environment, so it is preferable to ignore exceptions other than
            # critical errors.
            warning "#{mod}::#{const} loading failed: #{e.message}"
          end
        end
        checked_modules[mod] = true
      }.nonzero?
        # Loops until all constants have been checked.
      end
    end

    def build
      # If the script was run and autoload is enabled, attempt to autoload libraries.
      if @option.force_autoload?
        attempt_load_autoload(@ignore_modules)
      end

      @post_env = RuntimeEnvironment.save
      # NOTE: From this point, $LOADED_FEATURES has been captured, so it is now
      # safe to call require_relative.

      ENV.replace(@pre_env.env)

      # It might be useful to reset the current directory to the point where the
      # command was launched, especially when implementing the builder object.
      Dir.chdir(@pre_env.pwd)

      require_relative "direction"
      direction = Direction.new(@post_env, @pre_env, @option)

      if @option.use_inno_setup?
        # Native on Windows; on POSIX allow it when an ISCC command is
        # available (e.g. via Wine wrapper scripts or in tests).
        if Gem.win_platform? || system("command -v ISCC > /dev/null 2>&1")
          direction.build_inno_setup_installer
        else
          raise "Inno Setup is only supported on Windows (no ISCC command found in PATH)"
        end
      elsif @option.macosx_bundle
        direction.build_macosx_bundle(@option.macosx_bundle)
      elsif @option.output_dir
        direction.build_output_dir(@option.output_dir)
      elsif @option.output_zip
        direction.build_zip(@option.output_zip)
      elsif @option.cosmo_zip?
        direction.build_cosmo_zip_exe
      else
        direction.build_stab_exe
      end
    rescue RuntimeError => e
      fatal_error e.message
    end
  end
end
