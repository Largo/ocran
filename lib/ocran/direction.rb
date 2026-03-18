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

      # Remove any absolute path to bundler/setup from RUBYOPT.
      # When building under `bundle exec`, RUBYOPT contains `-r/absolute/path/bundler/setup`.
      # That path doesn't exist inside the packed executable's environment, causing Ruby to
      # print "RubyGems were not loaded" / "did_you_mean was not loaded" warnings on startup.
      # We strip the flag regardless of install prefix because the gem may live in a user gem
      # directory that doesn't share a prefix with RbConfig::TOPDIR (e.g. on CI runners).
      @rubyopt = @rubyopt.gsub(/-r\S*\/bundler\/setup/, "").strip
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
      if Gem.win_platform?
        require_relative "library_detector"
      else
        require_relative "library_detector_posix"
      end
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
      # rubygems/core_ext/kernel_require.rb is loaded via IO.read+eval rather than require,
      # so it never appears in $LOADED_FEATURES and must be added manually.
      # We check multiple candidate locations because the layout varies by Ruby setup:
      # - Standard Ruby (including RubyInstaller on Windows): rubygems.rb lives in rubylibdir
      # - Ruby with rubygems-update (e.g. asdf on Linux/macOS): rubygems.rb lives in site_ruby
      # kernel_require.rb must be packed alongside the rubygems.rb that was actually loaded,
      # because rubygems.rb uses require_relative to load it.
      kernel_require_rel = "rubygems/core_ext/kernel_require.rb"
      unless features.any? { |f| f.to_posix.end_with?(kernel_require_rel) }
        # Prefer the location alongside the actually-loaded rubygems.rb, fall back to rubylibdir
        rubygems_feature = features.find { |f| f.to_posix.end_with?("/rubygems.rb") }
        candidate_dirs = []
        candidate_dirs << rubygems_feature.dirname if rubygems_feature
        candidate_dirs << Pathname(RbConfig::CONFIG["rubylibdir"])
        candidate_dirs.each do |base_dir|
          kernel_require_path = base_dir / kernel_require_rel
          if kernel_require_path.exist?
            features.push(kernel_require_path)
            break
          end
        end
      end

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

      # If net/http was loaded but openssl wasn't (it is only required lazily
      # at the point of an actual HTTPS connection), require it now inside the
      # OCRAN build process so that every transitive dependency — openssl.rb,
      # digest.so, and any other files pulled in by the extension — appears in
      # $LOADED_FEATURES and gets bundled alongside the application.
      openssl_so = Pathname(RbConfig::CONFIG["archdir"]) / "openssl.so"
      if openssl_so.exist? &&
          features.any? { |f| f.to_posix.end_with?("/net/http.rb") } &&
          features.none? { |f| f == openssl_so }
        say "Auto-loading openssl (net/http loaded but openssl not yet required)"
        before = $LOADED_FEATURES.dup
        require "openssl"
        ($LOADED_FEATURES - before).each do |f|
          path = Pathname(f).cleanpath
          features << path if path.absolute?
        end
      end

      say "Building #{@option.output_executable}"
      require_relative "build_helper"
      builder.extend(BuildHelper)

      # Add the ruby executable and DLL
      say "Adding ruby executable #{ruby_executable}"
      builder.copy_to_bin(bindir / ruby_executable, ruby_executable)
      if libruby_so
        # On POSIX systems, libruby.so is in libdir; on Windows, it's in bindir
        libruby_src = Gem.win_platform? ? bindir / libruby_so : libdir / libruby_so
        builder.copy_to_bin(libruby_src, libruby_so)

        # On POSIX systems, create symlinks (aliases) for libruby.so
        unless Gem.win_platform?
          libruby_aliases.each do |libruby_alias|
            builder.symlink_in_bin(libruby_so, libruby_alias)
          end
        end
      end

      # On POSIX systems, set LD_LIBRARY_PATH to find bundled shared libraries
      unless Gem.win_platform?
        extract_bin = File.join(EXTRACT_ROOT, BINDIR.to_s)
        builder.export("LD_LIBRARY_PATH", extract_bin)
        if RUBY_PLATFORM.include?("darwin")
          builder.export("DYLD_LIBRARY_PATH", extract_bin)
        end
      end

      # Windows-only: Add detected DLLs
      if Gem.win_platform? && @option.auto_detect_dlls?
        detect_dlls.each do |dll|
          next unless dll.subpath?(exec_prefix) && dll.extname?(".dll") && dll.basename != libruby_so

          say "Adding detected DLL #{dll}"
          if dll.subpath?(exec_prefix)
            builder.duplicate_to_exec_prefix(dll)
          else
            builder.copy_to_bin(dll, dll.basename)
          end
        end

        # Proactively include companion DLLs for loaded native extensions.
        # Native extensions (.so) may depend on DLLs in the same archdir
        # directory (e.g., libssl-3-x64.dll alongside openssl.so) that are
        # loaded lazily on first use. Scanning .so directories ensures those
        # DLLs are bundled even when the extension is required but not
        # exercised during the OCRAN dependency scan.
        features.select { |f| f.extname?(".so") && f.subpath?(exec_prefix) }
                .map(&:dirname).uniq
                .each do |dir|
          dir.each_child do |path|
            next unless path.file? && path.extname?(".dll")
            say "Adding companion DLL #{path}"
            builder.duplicate_to_exec_prefix(path)
          end
        end
      end

      # Windows-only: Add external manifest and builtin DLLs
      if Gem.win_platform?
        if (manifest = ruby_builtin_manifest)
          manifest.dirname.each_child do |path|
            next if path.directory?
            say "Adding builtin DLL/manifest #{path}"
            builder.duplicate_to_exec_prefix(path)
          end
        end

        # Include SxS assembly manifests for native extensions.
        # Each .so file may have an embedded manifest referencing a companion
        # *.so-assembly.manifest file in the same directory. Without these
        # manifests the SxS activation context fails (error 14001) at runtime.
        # Scan archdir and the extension dirs of all loaded gems.
        sxs_manifest_dirs = []
        archdir = Pathname(RbConfig::CONFIG["archdir"])
        sxs_manifest_dirs << archdir if archdir.exist? && archdir.subpath?(exec_prefix)
        if defined?(Gem)
          Gem.loaded_specs.each_value do |spec|
            next if spec.extensions.empty?
            ext_dir = Pathname(spec.extension_dir)
            sxs_manifest_dirs << ext_dir if ext_dir.exist? && ext_dir.subpath?(exec_prefix)
          end
        end
        sxs_manifest_dirs.each do |dir|
          dir.each_child do |path|
            next unless path.extname == ".manifest"
            say "Adding native extension assembly manifest #{path}"
            builder.duplicate_to_exec_prefix(path)
          end
        end

        # Add extra DLLs specified on the command line
        @option.extra_dlls.each do |dll|
          say "Adding supplied DLL #{dll}"
          builder.copy_to_bin(bindir / dll, dll)
        end
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

        verbose "\tgem_dir: #{spec.gem_dir}"
        verbose "\tgem_dir exists: #{File.directory?(spec.gem_dir)}"
        loaded_matches = include.include?(:loaded) ? features.select { |f| f.subpath?(spec.gem_dir) } : []
        verbose "\t:loaded candidates in features: #{loaded_matches.size}"
        loaded_matches.each { |f| verbose "\t  loaded: #{f}" }
        resource_count = include.include?(:files) && File.directory?(spec.gem_dir) ? spec.resource_files.size : 0
        verbose "\t:files (resource_files) count: #{resource_count}"

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

      # Windows-only: Workaround for RubyInstaller MSYS folder detection
      if Gem.win_platform?
        # RubyInstaller cannot find the msys folder if ../msys64/usr/bin/msys-2.0.dll is not present
        # (since RubyInstaller-2.4.1 rubyinstaller 2 issue 23)
        builder.touch('msys64/usr/bin/msys-2.0.dll')
      end

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
          verbose "\tlibfile: #{feature} -> src (no load path)"
          source_files << feature
          next
        end
        abs_load_path = Pathname(@post_env.expand_path(load_path))
        if abs_load_path == pre_working_directory
          verbose "\tlibfile: #{feature} -> src (pre-working-dir load path)"
          source_files << feature
        elsif feature.subpath?(exec_prefix)
          # Features found in the Ruby installation are put in the
          # temporary Ruby installation.
          verbose "\tlibfile: #{feature} -> exec_prefix"
          builder.duplicate_to_exec_prefix(feature)
        elsif (gem_path = GemSpecQueryable.find_gem_path(feature))
          # Features found in any other Gem path (e.g. ~/.gems) is put
          # in a special 'gems' folder.
          verbose "\tlibfile: #{feature} -> gem_home"
          builder.duplicate_to_gem_home(feature, gem_path)
        elsif feature.subpath?(src_prefix) || abs_load_path == working_directory
          # Any feature found inside the src_prefix automatically gets
          # added as a source file (to go in 'src').
          verbose "\tlibfile: #{feature} -> src (src_prefix/working_dir)"
          source_files << feature
          # Add the load path unless it was added by the script while
          # running (or we assume that the script can also set it up
          # correctly when running from the resulting executable).
          src_load_path << abs_load_path unless added_load_paths.include?(abs_load_path)
        elsif added_load_paths.include?(abs_load_path)
          # Any feature that exist in a load path added by the script
          # itself is added as a file to go into the 'src' (src_prefix
          # will be adjusted below to point to the common parent).
          verbose "\tlibfile: #{feature} -> src (script-added load path)"
          source_files << feature
        else
          # All other feature that can not be resolved go in the the
          # Ruby sitelibdir. This is automatically in the load path
          # when Ruby starts on Windows.
          # On POSIX systems the ruby binary has a compile-time prefix so the
          # extraction dir's sitelibdir is not on the load path; put
          # the file in src instead and add the load path to RUBYLIB.
          if Gem.win_platform?
            inst_sitelibdir = sitelibdir.relative_path_from(exec_prefix)
            builder.cp(feature, inst_sitelibdir / feature.relative_path_from(abs_load_path))
          else
            source_files << feature
            src_load_path << abs_load_path unless src_load_path.include?(abs_load_path)
          end
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

      # Bundle SSL certificates if OpenSSL was loaded (e.g. via net/http HTTPS)
      if defined?(OpenSSL)
        cert_file = Pathname(OpenSSL::X509::DEFAULT_CERT_FILE)
        if cert_file.file? && cert_file.subpath?(exec_prefix)
          say "Adding SSL certificate file #{cert_file}"
          builder.duplicate_to_exec_prefix(cert_file)
          builder.export("SSL_CERT_FILE", File.join(EXTRACT_ROOT, cert_file.relative_path_from(exec_prefix).to_posix))
        end

        cert_dir = Pathname(OpenSSL::X509::DEFAULT_CERT_DIR)
        if cert_dir.directory? && cert_dir.subpath?(exec_prefix)
          say "Adding SSL certificate directory #{cert_dir}"
          cert_dir.find.each do |path|
            next if path.directory?
            builder.duplicate_to_exec_prefix(path)
          end
          builder.export("SSL_CERT_DIR", File.join(EXTRACT_ROOT, cert_dir.relative_path_from(exec_prefix).to_posix))
        end
      end

      # Bundle Tcl/Tk library scripts if the Tk extension is loaded.
      # tcl86.dll and tk86.dll are auto-detected by DLL scanning, but the
      # Tcl/Tk script libraries (init.tcl etc.) must also be bundled so
      # that Tcl can find them relative to the DLL at runtime.
      if defined?(TclTkLib)
        exec_prefix.glob("**/lib/tcl[0-9]*/init.tcl").each do |init_tcl|
          tcl_lib_dir = init_tcl.dirname
          next unless tcl_lib_dir.subpath?(exec_prefix)
          say "Adding Tcl library files #{tcl_lib_dir}"
          tcl_lib_dir.find.each do |path|
            next if path.directory?
            builder.duplicate_to_exec_prefix(path)
          end
        end

        exec_prefix.glob("**/lib/tk[0-9]*/pkgIndex.tcl").each do |pkg_index|
          tk_lib_dir = pkg_index.dirname
          next unless tk_lib_dir.subpath?(exec_prefix)
          say "Adding Tk library files #{tk_lib_dir}"
          tk_lib_dir.find.each do |path|
            next if path.directory?
            builder.duplicate_to_exec_prefix(path)
          end
        end
      end

      # Set environment variable
      builder.export("RUBYOPT", rubyopt)
      # Add the load path that are required with the correct path after
      # src_prefix was adjusted.
      load_path = src_load_path.map { |path| SRCDIR / path.relative_path_from(inst_src_prefix) }.uniq

      # On POSIX systems, also add the packed Ruby standard library directories
      # to RUBYLIB. The Ruby binary has a compiled-in prefix pointing to the build
      # host, which doesn't exist on other systems (e.g., Docker with no Ruby).
      # By adding the extract-dir equivalents of rubylibdir, sitelibdir, etc. to
      # RUBYLIB, Ruby can find rubygems and the standard library in the packed tree.
      unless Gem.win_platform?
        core_lib_paths = all_core_dir
          .select { |dir| dir.subpath?(exec_prefix) }
          .map { |dir| dir.relative_path_from(exec_prefix) }
        archdir = Pathname(RbConfig::CONFIG["archdir"])
        if archdir.subpath?(exec_prefix)
          core_lib_paths << archdir.relative_path_from(exec_prefix)
        end
        load_path = core_lib_paths + load_path
      end

      builder.set_env_path("RUBYLIB", *load_path)
      builder.set_env_path("GEM_HOME", GEMDIR)

      gem_paths = [GEMDIR]
      # Gems installed under the Ruby prefix (exec_prefix) have their specs and
      # extension dirs placed there via duplicate_to_exec_prefix. Include
      # Gem.default_dir (relative to exec_prefix) in GEM_PATH so RubyGems can
      # find and activate them at runtime. This is required on both Windows
      # (e.g. fxruby/fox16 whose fox16_c.so lives in extension_dir under the
      # Ruby prefix) and POSIX (e.g. error_highlight default gems).
      default_gem_dir = Pathname(Gem.default_dir)
      if default_gem_dir.subpath?(exec_prefix)
        gem_paths << default_gem_dir.relative_path_from(exec_prefix)
      end
      builder.set_env_path("GEM_PATH", *gem_paths)

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

    def build_output_dir(path)
      require_relative "dir_builder"

      path = Pathname(path)
      say "Building directory #{path}"
      DirBuilder.new(path, &to_proc)
      say "Finished building directory #{path}"
    end

    def build_zip(path)
      require_relative "dir_builder"
      require "tmpdir"

      path = Pathname(path)
      say "Building zip #{path}"
      Dir.mktmpdir("ocran") do |tmpdir|
        build_output_dir(tmpdir)
        DirBuilder.create_zip(path, tmpdir)
      end
      say "Finished building #{path} (#{File.size(path)} bytes)"
    end

    def build_macosx_bundle(bundle_path)
      require_relative "stub_builder"
      require "fileutils"

      bundle_path  = Pathname(bundle_path)
      app_name     = bundle_path.basename.sub_ext("").to_s
      contents_dir = bundle_path / "Contents"
      macos_dir    = contents_dir / "MacOS"
      resources_dir = contents_dir / "Resources"

      FileUtils.mkdir_p(macos_dir.to_s)

      executable_path = macos_dir / app_name
      say "Building app bundle #{bundle_path}"

      StubBuilder.new(executable_path,
                      chdir_before: @option.chdir_before?,
                      debug_extract: @option.enable_debug_extract?,
                      debug_mode: @option.enable_debug_mode?,
                      enable_compression: @option.enable_compression?,
                      gui_mode: false,
                      icon_path: nil,
                      &to_proc) => builder

      if @option.icon_filename
        FileUtils.mkdir_p(resources_dir.to_s)
        icon_dest = resources_dir / "AppIcon#{@option.icon_filename.extname}"
        FileUtils.cp(@option.icon_filename.to_s, icon_dest.to_s)
      end

      bundle_id  = @option.bundle_identifier || "com.example.#{app_name}"
      icon_entry = @option.icon_filename ? "    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n" : ""

      File.write(contents_dir / "Info.plist", <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key>
          <string>#{app_name}</string>
          <key>CFBundleDisplayName</key>
          <string>#{app_name}</string>
          <key>CFBundleIdentifier</key>
          <string>#{bundle_id}</string>
          <key>CFBundleVersion</key>
          <string>1.0</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleExecutable</key>
          <string>#{app_name}</string>
        #{icon_entry}</dict>
        </plist>
      PLIST

      say "Finished building #{bundle_path} (#{builder.data_size} bytes decompressed)"
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
