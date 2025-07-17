# frozen_string_literal: true
require "rbconfig"
require "pathname"
require_relative "refine_pathname"
require_relative "host_config_helper"
require_relative "command_output"
require_relative "build_constants"

module Ocran
  class Direction
    using RefinePathname

    # Match the load path against standard library, site_ruby, and vendor_ruby paths
    # This regular expression matches:
    # - /ruby/3.0.0/
    # - /ruby/site_ruby/3.0.0/
    # - /ruby/vendor_ruby/3.0.0/
    RUBY_LIBRARY_PATH_REGEX = %r{/(ruby/(?:site_ruby/|vendor_ruby/)?\d+\.\d+\.\d+)/?$}i

    include BuildConstants, CommandOutput, HostConfigHelper

    attr_reader :ruby_executable, :rubyopt

    def initialize(post_env, pre_env, option)
      @post_env, @pre_env, @option = post_env, pre_env, option
      @ruby_executable = @option.windowed? ? rubyw_exe : ruby_exe

      # Initializes @rubyopt with the user-intended RUBYOPT environment variable.
      # This ensures that RUBYOPT matches the user's initial settings before any
      # modifications that may occur during script execution.
      @rubyopt = @option.rubyopt || pre_env.env["RUBYOPT"] || ""

      # FIXME: Remove the absolute path to bundler/setup from RUBYOPT
      # This is a temporary measure to ensure compatibility with self-extracting executables
      # built in a bundle exec environment, particularly for Ruby 3.2 and later where
      # absolute paths are included in RUBYOPT.
      # In the future, we plan to implement a more appropriate solution.
      @rubyopt = @rubyopt.gsub(%r(-r#{Regexp.escape(RbConfig::TOPDIR)}(/.*/bundler/setup)), "")
    end

    # Resolves the common root directory prefix from an array of absolute paths.
    # This method iterates over each file path, checking if they have a subpath
    # that matches a given execution prefix.
    def resolve_root_prefix(files)
      files.inject(files.first.dirname) do |current_root, file|
        next current_root if file.subpath?(exec_prefix)

        current_root.ascend.find do |candidate_root|
          path_from_root = file.relative_path_from(candidate_root)
        rescue ArgumentError
          raise "No common directory contains all specified files"
        else
          path_from_root.each_filename.first != ".."
        end
      end
    end

    # For RubyInstaller environments supporting Ruby 2.4 and above,
    # this method checks for the existence of a required manifest file
    def ruby_builtin_manifest
      manifest_path = exec_prefix / "bin/ruby_builtin_dlls/ruby_builtin_dlls.manifest"
      manifest_path.exist? ? manifest_path : nil
    end

    def detect_dlls
      require_relative "library_detector"
      LibraryDetector.loaded_dlls.map { |path| Pathname.new(path).cleanpath }
    end

    def find_gemspecs(features)
      require_relative "gem_spec_queryable"

      specs = []
      # If a Bundler Gemfile was provided, add all gems it specifies
      if @option.gemfile
        say "Scanning Gemfile"
        specs += GemSpecQueryable.scanning_gemfile(@option.gemfile).each do |spec|
          verbose "From Gemfile, adding gem #{spec.full_name}"
        end
      end
      if defined?(Gem)
        specs += Gem.loaded_specs.values
        # Now, we also detect gems that are not included in Gem.loaded_specs.
        # Therefore, we look for any loaded file from a gem path.
        specs += GemSpecQueryable.detect_gems_from(features, verbose: @option.verbose?)
      end
      # Prioritize the spec detected from Gemfile.
      specs.uniq!(&:name)
      specs
    end

    def normalized_features
      features = @post_env.loaded_features.map { |feature| Pathname(feature) }

      # Since https://github.com/rubygems/rubygems/commit/cad4cf16cf8fcc637d9da643ef97cf0be2ed63cb
      # rubygems/core_ext/kernel_require.rb is evaled and thus missing in $LOADED_FEATURES, so we can't find it and need to add it manually
      features.push(Pathname("rubygems/core_ext/kernel_require.rb"))

      # Convert all relative paths to absolute paths before building.
      # NOTE: In the future, different strategies may be needed before and after script execution.
      features.filter_map do |feature|
        if feature.absolute?
          feature
        elsif (load_path = @post_env.find_load_path(feature))
          feature.expand_path(@post_env.expand_path(load_path))
        else
          # This message occurs when paths for core library files (e.g., enumerator.so,
          # rational.so, complex.so, fiber.so, thread.rb, ruby2_keywords.rb) are not
          # found. These are integral to Ruby's standard libraries or extensions and
          # may not be located via normal load path searches, especially in RubyInstaller
          # environments.
          verbose "Load path not found for #{feature}, skip this feature"
          nil
        end
      end
    end

    def construct(builder)
      # Store the currently loaded files
      features = normalized_features

      say "Building #{@option.output_executable}"
      require_relative "build_helper"
      builder.extend(BuildHelper)

      # Add the ruby executable and DLL
      say "Adding ruby executable #{ruby_executable}"
      builder.copy_to_bin(bindir / ruby_executable, ruby_executable)
      if libruby_so
        builder.copy_to_bin(bindir / libruby_so, libruby_so)
      end

      # Add detected DLLs
      if @option.auto_detect_dlls?
        detect_dlls.each do |dll|
          next unless dll.subpath?(exec_prefix) && dll.extname?(".dll") && dll.basename != libruby_so

          say "Adding detected DLL #{dll}"
          if dll.subpath?(exec_prefix)
            builder.duplicate_to_exec_prefix(dll)
          else
            builder.copy_to_bin(dll, dll.basename)
          end
        end
      end

      # Add external manifest files
      if (manifest = ruby_builtin_manifest)
        say "Adding external manifest #{manifest}"
        builder.duplicate_to_exec_prefix(manifest)
      end

      # Add extra DLLs specified on the command line
      @option.extra_dlls.each do |dll|
        say "Adding supplied DLL #{dll}"
        builder.copy_to_bin(bindir / dll, dll)
      end

      # Searches for features that are loaded from gems, then produces a
      # list of files included in those gems' manifests. Also returns a
      # list of original features that caused those gems to be included.
      gem_files = find_gemspecs(features).flat_map do |spec|
        spec_file = Pathname(spec.loaded_from)
        # FIXME: From Ruby 3.2 onwards, launching Ruby with bundle exec causes
        # Bundler's loaded_from to point to the root directory of the
        # bundler gem, not returning the path to gemspec files. Here, we
        # are only collecting gemspec files.
        unless spec_file.file?
          verbose "Gem #{spec.full_name} root folder was not found, skipping"
          next []
        end

        # Add gemspec files
        if spec_file.subpath?(exec_prefix)
          builder.duplicate_to_exec_prefix(spec_file)
        elsif (gem_path = GemSpecQueryable.find_gem_path(spec_file))
          builder.duplicate_to_gem_home(spec_file, gem_path)
        else
          raise "Gem spec #{spec_file} does not exist in the Ruby installation. Don't know where to put it."
        end

        # Determine which set of files to include for this particular gem
        include = GemSpecQueryable.gem_inclusion_set(spec.name, @option.gem_options)
        say "Detected gem #{spec.full_name} (#{include.join(", ")})"

        spec.extend(GemSpecQueryable)

        actual_files = spec.find_gem_files(include, features)
        say "\t#{actual_files.size} files, #{actual_files.sum(0, &:size)} bytes"

        # Decide where to put gem files, either the system gem folder, or
        # GEMDIR.
        actual_files.each do |gemfile|
          if gemfile.subpath?(exec_prefix)
            builder.duplicate_to_exec_prefix(gemfile)
          elsif (gem_path = GemSpecQueryable.find_gem_path(gemfile))
            builder.duplicate_to_gem_home(gemfile, gem_path)
          else
            raise "Don't know where to put gemfile #{gemfile}"
          end
        end

        actual_files
      end
      gem_files.uniq!

      features -= gem_files

      # If requested, add all ruby standard libraries
      if @option.add_all_core?
        say "Will include all ruby core libraries"
        all_core_dir.each do |path|
          # Match the load path against standard library, site_ruby, and vendor_ruby paths
          unless (subdir = path.to_posix.match(RUBY_LIBRARY_PATH_REGEX)&.[](1))
            raise "Unexpected library path format (does not match core dirs): #{path}"
          end
          path.find.each do |src|
            next if src.directory?
            a = Pathname(subdir) / src.relative_path_from(path)
            builder.copy_to_lib(src, Pathname(subdir) / src.relative_path_from(path))
          end
        end
      end

      # Include encoding support files
      if @option.add_all_encoding?
        @post_env.load_path.each do |load_path|
          load_path = Pathname(@post_env.expand_path(load_path))
          next unless load_path.subpath?(exec_prefix)

          enc_dir = load_path / "enc"
          next unless enc_dir.directory?

          enc_files = enc_dir.find.select { |path| path.file? && path.extname?(".so") }
          say "Including #{enc_files.size} encoding support files (#{enc_files.sum(0, &:size)} bytes, use --no-enc to exclude)"
          enc_files.each do |path|
            builder.duplicate_to_exec_prefix(path)
          end
        end
      else
        say "Not including encoding support files"
      end

      # Workaround: RubyInstaller cannot find the msys folder if ../msys64/usr/bin/msys-2.0.dll is not present (since RubyInstaller-2.4.1 rubyinstaller 2 issue 23)
      # Add an empty file to /msys64/usr/bin/msys-2.0.dll if the dll was not required otherwise
      builder.touch('msys64/usr/bin/msys-2.0.dll')

      # Find the source root and adjust paths
      source_files = @option.source_files.dup
      src_prefix = resolve_root_prefix(source_files)

      # Find features and decide where to put them in the temporary
      # directory layout.
      src_load_path = []
      # Add loaded libraries (features, gems)
      say "Adding library files"
      added_load_paths = (@post_env.load_path - @pre_env.load_path).map { |load_path| Pathname(@post_env.expand_path(load_path)) }
      pre_working_directory = Pathname(@pre_env.pwd)
      working_directory = Pathname(@post_env.pwd)
      features.each do |feature|
        load_path = @post_env.find_load_path(feature)
        if load_path.nil?
          source_files << feature
          next
        end
        abs_load_path = Pathname(@post_env.expand_path(load_path))
        if abs_load_path == pre_working_directory
          source_files << feature
        elsif feature.subpath?(exec_prefix)
          # Features found in the Ruby installation are put in the
          # temporary Ruby installation.
          builder.duplicate_to_exec_prefix(feature)
        elsif (gem_path = GemSpecQueryable.find_gem_path(feature))
          # Features found in any other Gem path (e.g. ~/.gems) is put
          # in a special 'gems' folder.
          builder.duplicate_to_gem_home(feature, gem_path)
        elsif feature.subpath?(src_prefix) || abs_load_path == working_directory
          # Any feature found inside the src_prefix automatically gets
          # added as a source file (to go in 'src').
          source_files << feature
          # Add the load path unless it was added by the script while
          # running (or we assume that the script can also set it up
          # correctly when running from the resulting executable).
          src_load_path << abs_load_path unless added_load_paths.include?(abs_load_path)
        elsif added_load_paths.include?(abs_load_path)
          # Any feature that exist in a load path added by the script
          # itself is added as a file to go into the 'src' (src_prefix
          # will be adjusted below to point to the common parent).
          source_files << feature
        else
          # All other feature that can not be resolved go in the the
          # Ruby sitelibdir. This is automatically in the load path
          # when Ruby starts.
          inst_sitelibdir = sitelibdir.relative_path_from(exec_prefix)
          builder.cp(feature, inst_sitelibdir / feature.relative_path_from(abs_load_path))
        end
      end

      # Recompute the src_prefix. Files may have been added implicitly
      # while scanning through features.
      inst_src_prefix = resolve_root_prefix(source_files)

      # Add explicitly mentioned files
      say "Adding user-supplied source files"
      source_files.each do |source|
        target = builder.resolve_source_path(source, inst_src_prefix)

        if source.directory?
          builder.mkdir(target)
        else
          builder.cp(source, target)
        end
      end

      # Set environment variable
      builder.export("RUBYOPT", rubyopt)
      # Add the load path that are required with the correct path after
      # src_prefix was adjusted.
      load_path = src_load_path.map { |path| SRCDIR / path.relative_path_from(inst_src_prefix) }.uniq
      builder.set_env_path("RUBYLIB", *load_path)
      builder.set_env_path("GEM_PATH", GEMDIR)

      # Add the opcode to launch the script
      installed_ruby_exe = BINDIR / ruby_executable
      target_script = builder.resolve_source_path(@option.script, inst_src_prefix)
      builder.exec(installed_ruby_exe, target_script, *@option.argv)
    end

    def to_proc
      method(:construct).to_proc
    end

    def build_inno_setup_installer
      require_relative "inno_setup_script_builder"
      iss_builder = InnoSetupScriptBuilder.new(@option.inno_setup_script)

      require_relative "launcher_batch_builder"
      launcher_builder = LauncherBatchBuilder.new(
        chdir_before: @option.chdir_before?,
        title: @option.output_executable.basename.sub_ext("")
      )

      require_relative "build_facade"
      builder = BuildFacade.new(iss_builder, launcher_builder)

      if @option.icon_filename
        builder.cp(@option.icon_filename, File.basename(@option.icon_filename))
      end

      construct(builder)

      say "Build launcher batch file"
      launcher_path = launcher_builder.build
      verbose File.read(launcher_path)
      builder.cp(launcher_path, "launcher.bat")

      say "Build inno setup script file"
      iss_path = iss_builder.build
      verbose File.read(iss_path)

      say "Running Inno Setup Command-Line compiler (ISCC)"
      iss_builder.compile(verbose: @option.verbose?)

      say "Finished building installer file"
    end

    def build_stab_exe
      require_relative "stub_builder"

      if @option.enable_debug_mode?
        say "Enabling debug mode in executable"
      end

      StubBuilder.new(@option.output_executable,
                      chdir_before: @option.chdir_before?,
                      debug_extract: @option.enable_debug_extract?,
                      debug_mode: @option.enable_debug_mode?,
                      enable_compression: @option.enable_compression?,
                      gui_mode: @option.windowed?,
                      icon_path: @option.icon_filename,
                      &to_proc) => builder
      say "Finished building #{@option.output_executable} (#{@option.output_executable.size} bytes)"
      say "After decompression, the data will expand to #{builder.data_size} bytes."
    end
  end
end
