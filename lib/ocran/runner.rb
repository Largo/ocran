# frozen_string_literal: true

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
      say "Loading script to check dependencies"
      $PROGRAM_NAME = @option.script.to_s
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
        direction.build_inno_setup_installer
      else
        direction.build_stab_exe
      end
    rescue RuntimeError => e
      fatal_error e.message
    end
  end
end
