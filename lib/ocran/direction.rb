# frozen_string_literal: true
require "rbconfig"
require "pathname"
require "set"
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

    # Core libraries provided by glibc and the dynamic loader. These must
    # never be bundled: they are tightly coupled to the target system's
    # ld.so, and shipping a foreign copy breaks the dynamic linker. The
    # libnss_* plugins are dlopened by the target's glibc and must match it.
    LINUX_SYSTEM_LIBRARY_RE = /\A(?:ld-linux|ld64|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libnsl\.so|libresolv\.so|libmvec\.so|libanl\.so|libBrokenLocale\.so|libnss_)/

    include BuildConstants, CommandOutput, HostConfigHelper

    # Packed name of the interpreter when a cosmopolitan Ruby payload is
    # used (--cosmo-ruby); the source APE is packed under this name.
    COSMO_RUBY_EXE = "ruby.com"

    # File name extensions of loadable native binaries that a gem may
    # ship or build. None of them can be loaded by the cosmopolitan Ruby
    # payload, which is statically linked and has no dlopen.
    NATIVE_BINARY_EXTENSIONS = %w[.so .bundle .dll].freeze

    # Native binaries a gem ships or has had built for it, i.e. the files
    # that make it unusable under the cosmopolitan Ruby payload.
    #
    # spec.extensions alone does NOT identify a native gem: a precompiled
    # platform gem (e.g. sqlite3-2.9.5-x86_64-linux-gnu) has an empty
    # extensions array because nothing is compiled at install time, yet it
    # ships a prebuilt sqlite3_native.so inside its lib directory. Both the
    # gem directory and the extension directory (where RubyGems puts the
    # products of a source build) are scanned.
    def self.gem_native_binaries(spec)
      ext_dir =
        begin
          spec.extension_dir
        rescue StandardError
          nil
        end
      pattern = "**/*{#{NATIVE_BINARY_EXTENSIONS.join(",")}}"
      [spec.gem_dir, ext_dir].compact.uniq.flat_map { |dir|
        next [] unless File.directory?(dir)

        Dir.glob(pattern, base: dir).map { |rel| Pathname(File.join(dir, rel)) }
      }.uniq
    end

    # Decides how a gem detected on the build host has to be treated when
    # a cosmopolitan Ruby payload is packed (--cosmo-ruby). Returns a pair
    # of a disposition and the gem's native binaries:
    #
    #   [:pack, []]                  pure Ruby gem, pack it as usual
    #   [:payload_provides, files]   native, but the payload ships the same
    #                                gem itself: skip the host copy and let
    #                                the payload's own version serve
    #   [:incompatible, files]       native and not provided by the payload:
    #                                the build must fail
    def self.cosmo_gem_disposition(spec, payload_gem_names)
      native_files = gem_native_binaries(spec)
      return [:pack, native_files] if spec.extensions.empty? && native_files.empty?

      if payload_gem_names.include?(spec.name)
        [:payload_provides, native_files]
      else
        [:incompatible, native_files]
      end
    end

    # Human readable reason why a gem counts as native, for build messages.
    def self.cosmo_native_reason(spec, native_files)
      reasons = []
      reasons << "declares native extensions" if spec.extensions.any?
      if native_files.any?
        names = native_files.map { |file| File.basename(file) }.uniq
        reasons << "ships prebuilt binaries (#{names.join(", ")})"
      end
      reasons.join(" and ")
    end

    attr_reader :ruby_executable, :rubyopt

    def initialize(post_env, pre_env, option)
      @post_env, @pre_env, @option = post_env, pre_env, option
      @ruby_executable =
        if @option.cosmo_ruby
          COSMO_RUBY_EXE
        else
          @option.windowed? ? rubyw_exe : ruby_exe
        end

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
        begin
          require_relative "library_detector"
        rescue LoadError => e
          # LibraryDetector needs fiddle, a bundled gem since Ruby 3.5. In a
          # Bundler context (e.g. building with --gemfile) requiring it is
          # refused unless the Gemfile lists fiddle, so degrade to no DLL
          # auto-detection instead of aborting the build.
          warning "DLL auto-detection disabled (#{e.message}). Add fiddle to the Gemfile, or use --dll to include DLLs manually."
          return []
        end
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
        foreign = foreign_bundle_gem_names
        specs += Gem.loaded_specs.each_value.reject { |spec| foreign.include?(spec.name) }
        # Now, we also detect gems that are not included in Gem.loaded_specs.
        # Therefore, we look for any loaded file from a gem path.
        specs += GemSpecQueryable.detect_gems_from(features, verbose: @option.verbose?)
      end
      # Prioritize the spec detected from Gemfile.
      specs.uniq!(&:name)
      specs
    end

    # The gems RubyGems had already activated for a bundle that is not the
    # application's, by the time OCRAN started.
    #
    # `bundle exec` activates every gem of its bundle before the command it
    # runs executes a single line, so Gem.loaded_specs describes the build
    # environment as much as the application. When the two bundles are the
    # same - `bundle exec ocran app.rb` from the application's own directory,
    # the ordinary case - that is exactly right and nothing is dropped. When
    # they differ, packing the build environment's bundle adds tens of
    # megabytes of code the application can never load: the packaged app runs
    # under its own Gemfile, so gems from a foreign bundle are dead weight
    # even when they are packed.
    #
    # Only activation is discounted, not use: anything the dependency run
    # actually loaded is still found through $LOADED_FEATURES by
    # detect_gems_from, and everything the application's Gemfile names is
    # added by the Gemfile scan. This is the same rule that already applies
    # to a build outside Bundler, where --gemfile is what pulls in gems the
    # dependency run does not load.
    def foreign_bundle_gem_names
      @foreign_bundle_gem_names ||=
        if foreign_build_bundle?
          verbose "Ignoring #{@pre_env.activated_gems.size} gems activated by the build environment's bundle " \
                  "#{@pre_env.env["BUNDLE_GEMFILE"]}"
          @pre_env.activated_gems.to_set
        else
          Set.new
        end
    end

    # Whether OCRAN itself was started under a bundle other than the one the
    # application runs under.
    def foreign_build_bundle?
      return false unless @pre_env.bundler_setup_loaded?

      build_gemfile = @pre_env.env["BUNDLE_GEMFILE"]
      return false if build_gemfile.nil? || build_gemfile.empty?

      app_gemfile = @option.application_gemfile
      return true if app_gemfile.nil?

      !same_file?(build_gemfile, app_gemfile)
    end

    def same_file?(a, b)
      File.identical?(a, b) || File.expand_path(a) == File.expand_path(b)
    end

    # Packed name of the file BUNDLER_SETUP is pointed at.
    BUNDLER_SETUP_NOOP = Pathname("no_bundler_setup.rb")

    # Keeps the environment of whoever launches the packaged application
    # from dragging Bundler into it.
    #
    # A packaged application carries its own gems and its own Gemfile; the
    # bundle of the machine it is started from means nothing to it, and
    # anything of that bundle that survives into the process is fatal rather
    # than merely wrong - Bundler aborts with GemNotFound as soon as it
    # cannot materialize gems that were never packed. RUBYOPT is already
    # overwritten wholesale, but that alone stopped being enough: RubyGems
    # now requires the file named by BUNDLER_SETUP at interpreter startup,
    # which is how current Bundler versions set a process up, and
    # BUNDLE_GEMFILE would still send the application's own
    # `require "bundler/setup"` at the wrong Gemfile.
    #
    # BUNDLER_SETUP names a file to require, so it cannot simply be blanked
    # - an empty value is still truthy and RubyGems would raise trying to
    # require it. It is pointed at an empty packed file instead. Bundler
    # does treat empty BUNDLE_GEMFILE and BUNDLE_LOCKFILE as unset, which is
    # what lets the application find the Gemfile packed beside it.
    def neutralize_bundler_env(builder)
      builder.touch(BUNDLER_SETUP_NOOP)
      builder.set_env_path("BUNDLER_SETUP", BUNDLER_SETUP_NOOP)
      builder.export("BUNDLE_GEMFILE", "")
      builder.export("BUNDLE_LOCKFILE", "")
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
        # Prefer the location alongside the actually-loaded rubygems.rb, fall back to
        # rubylibdir. Consider every feature ending in "/rubygems.rb", because a plain
        # suffix match can also hit unrelated files such as bundler's
        # lib/bundler/source/rubygems.rb (loaded before rubygems.rb under bundle exec);
        # the existence check below skips candidates without the core_ext file.
        candidate_dirs = features.select { |f| f.to_posix.end_with?("/rubygems.rb") }.map(&:dirname)
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

      # With --cosmo-ruby, run the payload interpreter once on the build
      # host: this validates that it works, provides its embedded gem
      # directory (needed for GEM_PATH below) and its version for the
      # host-vs-payload skew warning. Dependency detection has already
      # run under the *host* Ruby, so stdlib/gem resolution may differ
      # when the versions diverge.
      if @option.cosmo_ruby
        # Kernel#load, matching Option#load_cosmo_toolchain: the file may
        # already have been loaded that way at option-parse time, and
        # require_relative would then run it a second time.
        load File.expand_path("cosmo_toolchain.rb", __dir__) unless defined? CosmoToolchain
        @cosmo_ruby_info = CosmoToolchain.query_ruby(@option.cosmo_ruby)
        say "Packaging cosmopolitan Ruby #{@cosmo_ruby_info[:version]} (#{@option.cosmo_ruby})"
        if RUBY_VERSION.split(".").take(2) != @cosmo_ruby_info[:version].split(".").take(2)
          warning "Dependency detection ran under the host Ruby #{RUBY_VERSION}, but the packed cosmopolitan Ruby is #{@cosmo_ruby_info[:version]}; stdlib and gem behavior may differ between these versions"
        end
      end

      # If net/http was loaded but openssl wasn't (it is only required lazily
      # at the point of an actual HTTPS connection), require it now inside the
      # OCRAN build process so that every transitive dependency — openssl.rb,
      # digest.so, and any other files pulled in by the extension — appears in
      # $LOADED_FEATURES and gets bundled alongside the application.
      # Skipped with --cosmo-ruby: the payload interpreter carries its own
      # (statically linked) openssl, and the host's files would be excluded
      # from the package anyway.
      openssl_so = Pathname(RbConfig::CONFIG["archdir"]) / "openssl.so"
      if !@option.cosmo_ruby &&
          openssl_so.exist? &&
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
      if @option.cosmo_ruby
        # The cosmopolitan Ruby APE is fully self-contained: a static
        # binary with the standard library embedded in its ZIP store
        # (/zip/lib/ruby/...). No libruby, no shared libraries and no
        # LD_LIBRARY_PATH are needed — pack the single file and be done.
        #
        # Except in ZIP packaging mode, where the output IS that binary and
        # the application is injected into it: packing a copy of the
        # interpreter into itself would double the size of the executable
        # for nothing.
        if @option.cosmo_zip?
          say "Injecting the application into the ZIP store of #{@option.cosmo_ruby}"
        else
          builder.copy_to_bin(Pathname(@option.cosmo_ruby), ruby_executable)
        end
      else
        ruby_source = bindir / ruby_executable
        if !Gem.win_platform? && File.binread(ruby_source, 2) == "#!"
          # On some distros (e.g. Fedora), bindir/ruby is a dispatcher shell
          # script ("rubypick") rather than the interpreter itself, which
          # cannot run on a system without Ruby. Pack the currently running
          # interpreter binary under the expected name instead.
          real_ruby = Pathname("/proc/self/exe")
          raise "#{ruby_source} is a wrapper script and the real interpreter could not be determined" unless real_ruby.exist?

          say "#{ruby_source} is a wrapper script; packing #{real_ruby.realpath} instead"
          builder.copy_to_bin(real_ruby.realpath, ruby_executable)
        else
          builder.copy_to_bin(ruby_source, ruby_executable)
        end
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

      # Linux: bundle detected shared libraries (e.g. libyaml, libssl,
      # libcrypt) next to libruby so the executable also runs on systems
      # where they are missing or have different sonames (the stub already
      # points LD_LIBRARY_PATH at the packed bin directory). Core glibc
      # libraries and the loader are never bundled - they must come from the
      # target system. Ruby native extensions are packed as features, not
      # here. Not needed with --cosmo-ruby: the APE payload is static.
      if RUBY_PLATFORM.include?("linux") && @option.auto_detect_dlls? && !@option.cosmo_ruby
        feature_set = features.to_set
        feature_realpaths = features.filter_map { |f| f.realpath rescue nil }.to_set
        # Ruby native extensions live in these directories and are packed as
        # features; they must not be duplicated into bin.
        ruby_arch_dirs = RbConfig::CONFIG.values_at("archdir", "sitearchdir", "vendorarchdir")
          .compact.map { |dir| Pathname(dir) }
        detect_dlls.each do |dll|
          basename = dll.basename.to_s
          next unless basename.match?(/\.so(\.|\z)/)
          next if basename.match?(LINUX_SYSTEM_LIBRARY_RE)
          # libruby is packed with its aliases already
          next if basename.start_with?("libruby")
          next if feature_set.include?(dll) || feature_realpaths.include?(dll)
          next if ruby_arch_dirs.any? { |dir| dll.subpath?(dir) } || dll.to_posix.match?(%r{/gems/})
          next unless dll.file?

          say "Adding detected shared library #{dll}"
          builder.copy_to_bin(dll, basename)
          # The loader may request a library by a less specific soname than
          # the fully versioned file name recorded in the memory map (e.g.
          # libssl.so.3 for libssl.so.3.2.4). Provide symlink aliases for
          # each shorter version suffix.
          alias_name = basename
          while (shorter = alias_name.sub(/\.\d+[^.]*\z/, "")) != alias_name && shorter.include?(".so")
            builder.symlink_in_bin(basename, shorter)
            alias_name = shorter
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

      # Gem directories whose packing was skipped because the cosmopolitan
      # Ruby payload provides the gem itself; loaded features from these
      # directories must not be packed either.
      cosmo_skipped_gem_dirs = []

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

        if @option.cosmo_ruby
          # Default gems of the *host* Ruby are part of its stdlib; the
          # cosmopolitan Ruby ships its own stdlib and default/bundled
          # gems in its embedded ZIP store, so do not pack them (a host
          # 3.x copy would shadow the payload's version).
          if spec.respond_to?(:default_gem?) && spec.default_gem?
            verbose "Skipping default gem #{spec.full_name} (provided by the cosmopolitan Ruby's embedded stdlib)"
            next []
          end
          # Native gems compile (or were precompiled) against a host Ruby
          # ABI and platform; they cannot load under the x86_64-cosmo
          # payload, which is statically linked and cannot dlopen. This
          # covers both source-installed gems (spec.extensions) and
          # precompiled platform gems, which declare no extensions but
          # ship their .so inside the gem directory.
          # When the payload provides the same gem itself (e.g. json,
          # psych are statically linked into the APE), skip the host copy
          # so the payload's own version is used — packing the host .rb
          # files would shadow the payload's and could mismatch the
          # linked-in C extension. Otherwise fail clearly rather than
          # produce a broken executable.
          disposition, native_files = self.class.cosmo_gem_disposition(spec, @cosmo_ruby_info[:gem_names])
          if disposition != :pack
            reason = self.class.cosmo_native_reason(spec, native_files)
            if disposition == :payload_provides
              say "Skipping native gem #{spec.full_name} (#{reason}): the cosmopolitan Ruby provides its own #{spec.name}"
              cosmo_skipped_gem_dirs << Pathname(spec.gem_dir) if File.directory?(spec.gem_dir)
              ext_dir =
                begin
                  spec.extension_dir
                rescue StandardError
                  nil
                end
              cosmo_skipped_gem_dirs << Pathname(ext_dir) if ext_dir && File.directory?(ext_dir)
              next []
            end
            raise "Gem #{spec.full_name} is native (#{reason}) and cannot run under the packed cosmopolitan Ruby (x86_64-cosmo, static): exclude the gem or package without --cosmo-ruby"
          end
        end

        # Add gemspec files
        local_gem_dir = nil
        if spec_file.subpath?(exec_prefix)
          builder.duplicate_to_exec_prefix(spec_file)
        elsif (gem_path = GemSpecQueryable.find_gem_path(spec_file))
          builder.duplicate_to_gem_home(spec_file, gem_path)
        else
          # Local development gems (Bundler `gemspec` or `path:` directives)
          # keep their gemspec inside the project tree, outside both the Ruby
          # installation and every gem path, so there is no installed gem
          # layout to mirror. Pack them into GEMDIR as if they were installed
          # there: generate the spec from the in-memory specification (the
          # on-disk gemspec often uses dynamic constructs such as
          # `git ls-files` that would fail in the packed app) and pack the
          # gem's files under gems/<full_name>/ below.
          say "Including local development gem #{spec.full_name} from #{spec_file.dirname}"
          local_gem_dir = Pathname(spec.gem_dir)
          builder.copy_to_gem(generate_gemspec_file(spec), Pathname("specifications") / "#{spec.full_name}.gemspec")
          # RubyGems refuses to activate a gem with extensions unless its
          # gem.build_complete marker exists. The extension files themselves
          # are packed via the loaded features or the extension-dir mirroring
          # below.
          if spec.extensions.any?
            api_version = Gem.respond_to?(:extension_api_version) ? Gem.extension_api_version : Gem.ruby_api_version
            builder.touch(GEMDIR / "extensions" / Gem::Platform.local.to_s / api_version / spec.full_name / "gem.build_complete")
          end
        end

        spec_dir = spec_file.dirname
        default_spec = spec_dir.basename.to_s == "default"
        # The gem's base directory: specs live in <base_dir>/specifications[/default]
        base_dir = default_spec ? spec_dir.dirname.dirname : spec_dir.dirname
        # Relative packed location of base_dir; nil when the gem lives outside
        # the Ruby prefix, in which case its files are packed under GEMDIR
        # with the same layout.
        packed_base = base_dir.subpath?(exec_prefix) ? base_dir.relative_path_from(exec_prefix) : GEMDIR

        # Default gemspecs live in a "specifications/default" directory, which
        # RubyGems only scans under Gem.default_dir. On rubies with a
        # compiled-in absolute prefix (e.g. distro Ruby on Fedora), that path
        # points to the build host and does not exist on the target system, so
        # activating such a gem (e.g. via a binstub) fails. Also place a copy
        # in the regular specifications directory of the same packed base
        # directory, where GEM_PATH makes it discoverable and its require
        # paths resolve to the packed gem files.
        if !Gem.win_platform? && default_spec
          builder.cp(spec_file, packed_base / "specifications" / spec_file.basename)
        end

        # Native-extension gems record successful builds in a gem.build_complete
        # marker under <base_dir>/extensions/...; without it RubyGems refuses to
        # activate the gem ("Ignoring x because its extensions are not built").
        # The marker can be absent from the packed tree either because the
        # distro relocates it (e.g. Fedora keeps it under /usr/lib64/gems/ruby
        # via a default_ext_dir_for override) or because the gem is a default
        # gem, which is exempt from the check on the host while its packed
        # regular-spec copy is not. Recreate the marker where RubyGems expects
        # it at runtime.
        if !Gem.win_platform? && spec.extensions.any?
          api_version = Gem.respond_to?(:extension_api_version) ? Gem.extension_api_version : Gem.ruby_api_version
          packed_ext_dir = Pathname("extensions") / Gem::Platform.local.to_s / api_version / spec.full_name
          host_marker = Pathname(spec.gem_build_complete_path)
          if default_spec || (File.exist?(host_marker) && !host_marker.subpath?(base_dir))
            builder.touch(packed_base / packed_ext_dir / "gem.build_complete")
          end
        end

        # Determine which set of files to include for this particular gem
        include = GemSpecQueryable.gem_inclusion_set(spec.name, @option.gem_options)
        say "Detected gem #{spec.full_name} (#{include.join(", ")})"

        spec.extend(GemSpecQueryable)

        verbose "\tgem_dir: #{spec.gem_dir}"
        verbose "\tgem_dir exists: #{File.directory?(spec.gem_dir)}"
        unless File.directory?(spec.gem_dir)
          verbose "\tGem directory does not exist (default gem?); packing loaded files via load path instead"
        end
        loaded_matches = include.include?(:loaded) ? features.select { |f| f.subpath?(spec.gem_dir) } : []
        verbose "\t:loaded candidates in features: #{loaded_matches.size}"
        loaded_matches.each { |f| verbose "\t  loaded: #{f}" }
        resource_count = include.include?(:files) && File.directory?(spec.gem_dir) ? spec.resource_files.size : 0
        verbose "\t:files (resource_files) count: #{resource_count}"

        actual_files = spec.find_gem_files(include, features)

        # Safety net: gems reaching this point are pure Ruby as far as
        # their gem and extension directories go (see the disposition
        # check above), but a file list can still pull in a native binary
        # from elsewhere. It cannot load under the cosmopolitan payload,
        # so exclude it loudly.
        if @option.cosmo_ruby
          native_files = actual_files.select { |f| NATIVE_BINARY_EXTENSIONS.any? { |ext| f.extname?(ext) } }
          if native_files.any?
            warning "Gem #{spec.full_name} contains native binaries that cannot run under the packed cosmopolitan Ruby; excluding: #{native_files.map(&:basename).join(", ")}"
            actual_files -= native_files
          end
        end

        say "\t#{actual_files.size} files, #{actual_files.sum(0, &:size)} bytes"

        # Decide where to put gem files, either the system gem folder, or
        # GEMDIR.
        actual_files.each do |gemfile|
          if gemfile.subpath?(exec_prefix)
            builder.duplicate_to_exec_prefix(gemfile)
          elsif (gem_path = GemSpecQueryable.find_gem_path(gemfile))
            builder.duplicate_to_gem_home(gemfile, gem_path)
          elsif local_gem_dir && gemfile.subpath?(local_gem_dir)
            # Mirror local development gem files into the packed GEM_HOME
            # under the gem directory matching the generated specification.
            builder.copy_to_gem(gemfile, Pathname("gems") / spec.full_name / gemfile.relative_path_from(local_gem_dir))
          else
            raise "Don't know where to put gemfile #{gemfile}"
          end
        end

        # When a distro builds native extensions outside the gem's base_dir
        # and loads them from there (e.g. Fedora's /usr/lib64/gems/ruby), the
        # loaded .so would be packed at a mirror path that is never on the
        # runtime load path. Pack such loaded extension files ONLY into the
        # extension directory RubyGems computes at runtime, which gem
        # activation puts on the load path. Appended to actual_files after
        # the generic copy above so they are claimed as gem files (and thus
        # excluded from the plain feature packing, where a bare .so on
        # RUBYLIB would shadow the gem) without also being mirrored at their
        # host location. The extension dir and the load location may be
        # aliased via symlinks in either direction, so match features against
        # the extension dir by realpath both ways.
        if !Gem.win_platform? && spec.extensions.any?
          host_ext_dir = Pathname(spec.extension_dir)
          if host_ext_dir.directory? && !host_ext_dir.subpath?(base_dir)
            alias_map = {}
            host_ext_dir.find.select(&:file?).each do |entry|
              real = begin
                entry.realpath
              rescue SystemCallError
                next
              end
              alias_map[real] = entry
            end
            features.each do |feature|
              real = begin
                feature.realpath
              rescue SystemCallError
                feature
              end
              entry = if feature.subpath?(host_ext_dir)
                        feature
                      elsif real.subpath?(host_ext_dir)
                        real
                      else
                        alias_map[feature] || alias_map[real]
                      end
              next unless entry

              builder.cp(feature, packed_base / packed_ext_dir / entry.relative_path_from(host_ext_dir))
              actual_files << feature
            end
          end
        end

        actual_files
      end
      gem_files.uniq!

      # On some distros parts of a gem are reachable through symlinks at other
      # locations (e.g. Fedora symlinks /usr/share/ruby/psych.rb into the
      # psych gem directory), so a feature and a packed gem file can denote
      # the same file under different paths. Compare realpaths when removing
      # gem files from the feature list; otherwise a stdlib-level duplicate
      # would be packed as well and shadow the packed gem at runtime.
      gem_file_set = (gem_files + gem_files.filter_map { |file| file.realpath rescue nil }).to_set
      features = features.reject do |feature|
        next true if gem_file_set.include?(feature)

        real = begin
          feature.realpath
        rescue SystemCallError
          nil
        end
        real && gem_file_set.include?(real)
      end

      # If requested, add all ruby standard libraries
      if @option.add_all_core? && @option.cosmo_ruby
        say "Skipping host core libraries (--add-all-core): the cosmopolitan Ruby embeds its own standard library"
      elsif @option.add_all_core?
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
      if @option.cosmo_ruby
        # Encoding extensions are statically linked into the payload.
        say "Encoding support is embedded in the cosmopolitan Ruby"
      elsif @option.add_all_encoding?
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
        # With --cosmo-ruby, files of the host Ruby installation must not
        # be packed: the payload interpreter resolves the standard library
        # from its embedded ZIP store, and a packed host-version copy (or
        # a host-ABI native extension) would be wrong for it.
        if @option.cosmo_ruby
          if feature.subpath?(exec_prefix)
            verbose "\tlibfile: #{feature} -> skipped (host Ruby installation; the cosmopolitan Ruby uses its embedded stdlib)"
            next
          elsif cosmo_skipped_gem_dirs.any? { |dir| feature.subpath?(dir) }
            verbose "\tlibfile: #{feature} -> skipped (gem provided by the cosmopolitan Ruby)"
            next
          elsif feature.extname?(".so") || feature.extname?(".bundle")
            warning "Excluding native extension file #{feature}: native extensions cannot run under the packed cosmopolitan Ruby"
            next
          end
        end

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
      neutralize_bundler_env(builder)
      # Add the load path that are required with the correct path after
      # src_prefix was adjusted.
      load_path = src_load_path.map { |path| SRCDIR / path.relative_path_from(inst_src_prefix) }.uniq

      # On POSIX systems, also add the packed Ruby standard library directories
      # to RUBYLIB. The Ruby binary has a compiled-in prefix pointing to the build
      # host, which doesn't exist on other systems (e.g., Docker with no Ruby).
      # By adding the extract-dir equivalents of rubylibdir, sitelibdir, etc. to
      # RUBYLIB, Ruby can find rubygems and the standard library in the packed tree.
      # Not with --cosmo-ruby: the host stdlib is not packed at all, and the
      # payload finds its own stdlib in its embedded ZIP store.
      unless Gem.win_platform? || @option.cosmo_ruby
        # Use the build Ruby's actual default load path in addition to the
        # RbConfig directories: some distros compile in extra entries that
        # RbConfig does not expose (e.g. Fedora's /usr/share/rubygems, where
        # rubygems.rb lives outside rubylibdir).
        default_load_paths = @pre_env.load_path.map { |dir| Pathname(@pre_env.expand_path(dir)) }
        archdir = Pathname(RbConfig::CONFIG["archdir"])
        core_lib_paths = (default_load_paths + all_core_dir + [archdir])
          .select { |dir| dir.subpath?(exec_prefix) }
          .map { |dir| dir.relative_path_from(exec_prefix) }
          .uniq
        load_path = core_lib_paths + load_path
      end

      builder.set_env_path("RUBYLIB", *load_path)
      builder.set_env_path("GEM_HOME", GEMDIR)

      gem_paths = [GEMDIR]
      # Gems installed under the Ruby prefix (exec_prefix) have their specs and
      # extension dirs placed there via duplicate_to_exec_prefix. Include every
      # Gem.path entry located under exec_prefix (relative to it) in GEM_PATH so
      # RubyGems can find and activate them at runtime. This is required on both
      # Windows (e.g. fxruby/fox16 whose fox16_c.so lives in extension_dir under
      # the Ruby prefix) and POSIX (e.g. error_highlight default gems). Distros
      # can split gems over several such directories - e.g. Fedora uses
      # /usr/share/gems for RPM-packaged (default) gems and /usr/local/share/gems
      # for user-installed ones - so Gem.default_dir alone is not enough.
      prefix_gem_dirs = (Gem.path.map { |dir| Pathname(dir) } + [Pathname(Gem.default_dir)])
        .select { |dir| dir.subpath?(exec_prefix) }
        .map { |dir| dir.relative_path_from(exec_prefix) }
        .uniq
      gem_paths += prefix_gem_dirs
      # RubyGems probes the default gem dir for writability at startup and
      # prints "Can't determine writability of default gem path" on stderr
      # when the directory does not exist in the packed layout - so always
      # create the packed prefix gem dirs, even when no specs landed there.
      prefix_gem_dirs.each { |dir| builder.mkdir(dir) }
      if @option.cosmo_ruby
        # When GEM_PATH is set, RubyGems no longer scans its compiled-in
        # default directory — which for the cosmopolitan Ruby is the /zip
        # store inside the binary, where its bundled gems live. Keep it
        # reachable by appending it explicitly.
        gem_paths << @cosmo_ruby_info[:default_gem_dir]
      end
      builder.set_env_path("GEM_PATH", *gem_paths)

      # Add the opcode to launch the script
      installed_ruby_exe = BINDIR / ruby_executable
      target_script = builder.resolve_source_path(@option.script, inst_src_prefix)
      builder.exec(installed_ruby_exe, target_script, *@option.argv)
    end

    # Writes the in-memory gem specification to a temporary file and returns
    # the file's path, for packing gemspecs that cannot be copied verbatim
    # from disk (e.g. local development gems). The Tempfile object is
    # retained because some builders (e.g. InnoSetupScriptBuilder) read
    # their source files only after construction has completed.
    def generate_gemspec_file(spec)
      require "tempfile"
      file = Tempfile.new(["#{spec.full_name}-", ".gemspec"])
      file.write(spec.to_ruby)
      file.close
      (@generated_gemspec_files ||= []) << file
      file.path
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

      # Record the launch events (exports + exec) so they can be replayed
      # into the wrapper stub executable below.
      require_relative "launcher_event_recorder"
      recorder = LauncherEventRecorder.new(launcher_builder)

      require_relative "build_facade"
      builder = BuildFacade.new(iss_builder, recorder)

      if @option.icon_filename
        builder.cp(@option.icon_filename, File.basename(@option.icon_filename))
      end

      construct(builder)

      say "Build launcher batch file"
      launcher_path = launcher_builder.build
      verbose File.read(launcher_path)
      builder.cp(launcher_path, "launcher.bat")

      require "tmpdir"
      Dir.mktmpdir("ocran") do |tmpdir|
        if @option.wrapper_exe?
          # Wrapper executable (pre-1.4/OCRA behavior): a small stub without
          # embedded files that runs the installed application directly from
          # {app}. It is installed next to the application files so that user
          # Inno Setup scripts can reference it by the --output name, e.g. in
          # [Run]/[UninstallRun] entries or for Windows service registration.
          wrapper_path = Pathname(tmpdir) / @option.output_executable.basename
          build_wrapper_exe(wrapper_path) { |stub| recorder.replay(stub) }
          builder.cp(wrapper_path, wrapper_path.basename)
        end

        say "Build inno setup script file"
        iss_path = iss_builder.build
        verbose File.read(iss_path)

        say "Running Inno Setup Command-Line compiler (ISCC)"
        iss_builder.compile(verbose: @option.verbose?)
      end

      say "Finished building installer file"
    end

    # Returns the path to the stub built from source with cosmocc when
    # --cosmo was given, or nil to use the pre-built stub shipped with
    # the gem. The build result is memoized (and CosmoToolchain caches
    # compiled stubs across runs), so multiple stubs per build (e.g.
    # wrapper executables) compile at most once.
    def cosmo_stub_path
      return nil unless @option.cosmo_cc

      @cosmo_stub_path ||= begin
        load File.expand_path("cosmo_toolchain.rb", __dir__) unless defined? CosmoToolchain
        say "Building launcher stub from source with cosmocc (#{@option.cosmo_cc})"
        path = CosmoToolchain.build_stub(@option.cosmo_cc)
        say "Using APE stub #{path}"
        path
      end
    end

    # Builds the small RUN_IN_EXE_DIR wrapper stub that starts the deployed
    # application directly from the directory the wrapper resides in.
    def build_wrapper_exe(wrapper_path)
      require_relative "stub_builder"
      say "Build wrapper executable #{wrapper_path.basename}"
      StubBuilder.new(wrapper_path,
                      chdir_before: @option.chdir_before?,
                      debug_mode: @option.enable_debug_mode?,
                      gui_mode: @option.windowed?,
                      icon_path: @option.icon_filename,
                      run_in_exe_dir: true,
                      stub_path: cosmo_stub_path) do |stub|
        yield(stub)
      end
    end

    def build_output_dir(path)
      require_relative "dir_builder"

      path = Pathname(path)
      say "Building directory #{path}"
      builder = DirBuilder.new(path, &to_proc)

      if @option.wrapper_exe?
        # Same wrapper as in Inno Setup builds: a doubleclickable executable
        # next to the launch script, usable e.g. for Windows service
        # registration from an unpacked zip. Disable with --no-wrapper-exe.
        build_wrapper_exe(path / @option.output_executable.basename) do |stub|
          builder.env.each { |name, value| stub.export(name, value) }
          if builder.exec_args
            image, script, argv = builder.exec_args
            stub.exec(image, script, *argv)
          end
        end
      end

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
                      stub_path: cosmo_stub_path,
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

    # Builds the executable by copying the cosmopolitan Ruby and injecting
    # the application into its ZIP store (--cosmo-ruby with an interpreter
    # that runs an embedded /zip/main.rb). No compiler runs, no launcher
    # stub is involved, and the resulting binary unpacks nothing when it
    # starts.
    def build_cosmo_zip_exe
      require_relative "zip_payload_builder"

      output = @option.output_executable
      ZipPayloadBuilder.new(output,
                            cosmo_ruby: @option.cosmo_ruby,
                            chdir_before: @option.chdir_before?,
                            debug_mode: @option.enable_debug_mode?,
                            &to_proc) => builder

      builder.ignored_symlinks.each do |link_path, target|
        verbose "Skipping symlink #{link_path} -> #{target} (ZIP members cannot be symlinks)"
      end

      if @option.icon_filename
        warning "--icon has no effect in this mode: the executable is a copy of the cosmopolitan Ruby, whose resources OCRAN does not rewrite"
      end
      if @option.enable_debug_extract?
        warning "--debug-extract has no effect in this mode: nothing is extracted, the application is read from the executable's own ZIP store"
      end

      _, _, unsupported = ZipPayloadBuilder.parse_rubyopt(rubyopt)
      unless unsupported.empty?
        warning "RUBYOPT #{unsupported.join(" ")} cannot be applied when the application is packed into the interpreter's ZIP store (the interpreter is already running); only -I and -r are replayed"
      end

      say "Finished building #{output} (#{output.size} bytes, #{builder.data_size} bytes of application data)"
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
                      stub_path: cosmo_stub_path,
                      &to_proc) => builder
      say "Finished building #{@option.output_executable} (#{@option.output_executable.size} bytes)"
      say "After decompression, the data will expand to #{builder.data_size} bytes."
    end
  end
end
