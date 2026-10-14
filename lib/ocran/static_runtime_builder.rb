# frozen_string_literal: true
require "pathname"
require "fileutils"
require "json"
require "digest"
require_relative "build_constants"
require_relative "command_output"
require_relative "zip_writer"
require_relative "zip_payload_builder"
require "tmpdir"

module Ocran
  # A static runtime for --static-runtime: a statically linked Windows Ruby
  # (ocran-runtime.exe), its own standard library and bundled gems
  # (lib/ruby/), and runtime.json describing both. Built by
  # runtime/build-runtime.sh (MinGW) or runtime/mswin/ (MSVC).
  class StaticRuntime
    attr_reader :dir, :info

    def self.load(dir)
      dir = Pathname(dir).expand_path
      json = dir / "runtime.json"
      raise "#{dir} is not an ocran static runtime (no runtime.json)" unless json.file?

      new(dir, JSON.parse(json.read))
    end

    def initialize(dir, info)
      @dir = Pathname(dir)
      @info = info
      raise "Unsupported runtime.json format #{info["format"].inspect} in #{dir}" unless info["format"] == 1
    end

    def executable = @dir / @info.fetch("executable")
    def ruby_version = @info.fetch("ruby_version")
    def os = @info.fetch("os", "windows")
    def windows? = os == "windows"
    def ruby_api_version = @info.fetch("ruby_api_version")
    def arch = @info.fetch("arch")
    def load_path = @info.fetch("load_path")
    def gem_dir = @info.fetch("gem_dir")
    def gem_platform = @info.fetch("gem_platform")
    def extension_api_version = @info.fetch("extension_api_version")
    def gems = @info.fetch("gems")

    # The runtime executable is what every packaged application runs, so it
    # is checked against the hash recorded when the runtime was built.
    def verify!
      exe = executable
      raise "#{exe} not found" unless exe.file?

      actual = Digest::SHA256.file(exe.to_s).hexdigest
      expected = @info.fetch("executable_sha256")
      return if actual == expected

      raise "#{exe} does not match its runtime.json (SHA-256 #{actual}, expected #{expected})"
    end

    # The C extension a .so file of the build host stands for, when the
    # runtime has it linked in: "lib/ruby/4.0.0/x64-mingw-ucrt/json/ext/parser.so"
    # is "json/ext/parser".
    def static_feature_for(path)
      path = path.to_s.sub(/\.(so|bundle|dll)\z/, "")
      @static_features ||= @info.fetch("static_features").sort_by { |f| -f.size }
      @static_features.find { |feature| path == feature || path.end_with?("/#{feature}") }
    end

    # Absolute path of a file of the runtime's lib/ruby tree, or nil.
    def lib_file(relative)
      path = @dir / relative
      path.file? ? path : nil
    end

    # The runtime's SDK (sdk/), for linking in more C extensions; nil when
    # the runtime was distributed without one.
    def sdk
      return @sdk if defined?(@sdk)

      require_relative "runtime_sdk"
      @sdk = (@dir / "sdk" / "link.args").file? ? RuntimeSdk.new(@dir / "sdk", arch: arch) : nil
    end
  end

  # Builder for --static-runtime: the output is a copy of the static runtime with
  # the application appended as a ZIP archive. Nothing is extracted at run
  # time; the runtime's stage 0 reads ocran/boot.rb from the archive, and
  # boot.rb serves the archive as a read-only directory tree rooted at the
  # executable's own path (C:/app/tool.exe/src/tool.rb).
  #
  # Direction lays an application out the way the extraction modes need
  # it: the build host's interpreter under bin/, its standard library and
  # gems under lib/ruby/, and so on. This builder translates that layout
  # onto the runtime:
  #
  # * the interpreter, DLLs and other executables are not packed - the
  #   runtime is the interpreter, and a DLL cannot be loaded from inside
  #   the archive;
  # * the standard library is the runtime's own, so it always matches the
  #   interpreter; a host file it does not have is not packed;
  # * gems the runtime ships (default and bundled gems) are packed from the
  #   runtime, other gems from the host;
  # * C extensions must be linked into the runtime: those it has are
  #   skipped, any other one fails the build.
  class StaticRuntimeBuilder
    include BuildConstants
    include CommandOutput

    # Where boot.rb finds the application root; replaced at run time.
    ROOT = "<ROOT>"
    BOOT_SCRIPT = File.expand_path("static_runtime/boot.rb", __dir__)
    NATIVE_EXTENSIONS = %w[.so .bundle].freeze
    # Files only the build host's interpreter needs.
    HOST_ONLY = %w[.dll .exe .manifest].freeze
    # RubyInstaller's hook into RubyGems and what it loads (including its
    # win32/dll_directory extension): it manages the DLL search paths of an
    # installed Ruby, which a static runtime has none of.
    RUBYINSTALLER_FILES = %r{\Alib/ruby/(site_ruby/[^/]+/(ruby_installer(/|\.rb\z)|rubygems/defaults/operating_system\.rb\z)|[^/]+/[^/]+/win32/dll_directory\.so\z)}

    attr_reader :data_size, :skipped, :shipped_dlls

    def initialize(path, runtime:, host_ruby_api_version:, host_arch:, chdir_before: false,
                   chdir_exe_dir: false, windowed: false, debug_mode: false, dlls: [], resources: nil)
      @path = Pathname(path)
      @dlls = dlls
      @resources = resources
      @runtime = runtime
      @host_api = host_ruby_api_version
      @host_arch = host_arch
      @chdir = chdir_exe_dir || chdir_before
      @windowed = windowed
      @debug_mode = debug_mode
      @entries = {}
      @env = {}
      @exec = nil
      @runtime_gems = {}
      @unsupported_native = []
      @skipped = Hash.new { |h, k| h[k] = [] }
      @data_size = 0
      @shipped_dlls = []

      yield(self) if block_given?

      finalize
    end

    def mkdir(target)
      name = normalize(target)
      @entries["#{name}/"] ||= nil unless name.empty?
    end

    def cp(source, target)
      name = normalize(target)
      source = Pathname(source)

      if name.start_with?("bin/") || name.start_with?("msys64/")
        skip(:host_interpreter, name)
      elsif name.match?(RUBYINSTALLER_FILES)
        skip(:rubyinstaller, name)
      elsif NATIVE_EXTENSIONS.include?(File.extname(name))
        native_extension(source, name)
      elsif HOST_ONLY.include?(File.extname(name).downcase)
        if name.start_with?("src/")
          warning "#{name} is packed, but a DLL or program inside the executable cannot be loaded or run from there"
          add(name, source)
        else
          skip(:host_interpreter, name)
        end
      elsif (gem = gem_of(name)) && @runtime.gems.key?(gem[0])
        runtime_gem(*gem)
      elsif (relative = stdlib_path(name))
        runtime_file = @runtime.lib_file(relative)
        if runtime_file
          add(relative, runtime_file)
        else
          skip(:not_in_runtime_stdlib, name)
        end
      else
        add(name, source)
      end
    end

    def symlink(link_path, target)
      skip(:symlink, "#{normalize(link_path)} -> #{target}")
    end

    # Variables only the build host's interpreter layout needs.
    HOST_ENV = %w[LD_LIBRARY_PATH DYLD_LIBRARY_PATH].freeze

    # Variables naming a file or directory for C code to read (OpenSSL's
    # CA certificates): C code cannot read inside the archive.
    C_PATH_ENV = %w[SSL_CERT_FILE SSL_CERT_DIR].freeze

    def export(name, value)
      return if HOST_ENV.include?(name.to_s)
      if C_PATH_ENV.include?(name.to_s) && value.to_s.start_with?(EXTRACT_ROOT.to_s)
        verbose "Not setting #{name}: OpenSSL cannot read inside the executable (it uses the Windows certificate store)"
        return
      end

      @env[name.to_s] = value.to_s
    end

    # The image is the host interpreter the extraction modes would start;
    # here the runtime is the interpreter.
    def exec(_image, script, *argv)
      raise "Script is already set" if @exec

      @exec = [normalize(script), argv.map(&:to_s)]
    end

    private

    def normalize(target)
      target.to_s.tr("\\", "/").delete_prefix("./").chomp("/")
    end

    def add(name, source)
      return if @entries.key?(name)

      @entries[name] = source
      @data_size += File.size(source)
    end

    def skip(reason, name)
      @skipped[reason] << name
    end

    def native_extension(source, name)
      if (feature = @runtime.static_feature_for(name))
        skip(:static_extension, "#{name} (#{feature})")
      else
        @unsupported_native << [name, source]
      end
    end

    # Relative path inside the runtime's lib/ruby tree for a target in the
    # host's standard library directory (lib/ruby/<api>/...), with the
    # host's architecture directory mapped to the runtime's; nil for any
    # other target.
    def stdlib_path(name)
      prefix = "lib/ruby/#{@host_api}/"
      return nil unless name.start_with?(prefix)

      rest = name.delete_prefix(prefix)
      rest = "#{@runtime.arch}/#{rest.delete_prefix("#{@host_arch}/")}" if rest.start_with?("#{@host_arch}/")
      "lib/ruby/#{@runtime.ruby_api_version}/#{rest}"
    end

    GEM_PATH_ENTRY = %r{(?:gems|specifications(?:/default)?|extensions/[^/]+/[^/]+)/([^/]+?)(?:\.gemspec)?(?:/(.*))?\z}

    # [name, full name, path inside the gem directory] of the gem a target
    # belongs to when it lies in a gem path (gems/, specifications/,
    # extensions/), else nil. The path is nil for specs and extensions.
    def gem_of(name)
      match = name.match(%r{(?:\A|/)gems/[^/]+/#{GEM_PATH_ENTRY}}) || name.match(%r{\Agems/#{GEM_PATH_ENTRY}})
      return nil unless match

      full_name = match[1]
      inner = name.include?("/gems/#{full_name}/") || name.start_with?("gems/gems/#{full_name}/") ? match[2] : nil
      [full_name.sub(/-\d[^-]*(?:-.+)?\z/, ""), full_name, inner] # name-1.2.3[-x64-mingw-ucrt]
    end

    # A file of a gem the runtime ships itself: packed from the runtime,
    # whose copy matches the C extensions linked into it.
    def runtime_gem(name, host_full_name, inner)
      spec = @runtime.gems.fetch(name)
      runtime_full_name = File.basename(spec, ".gemspec")
      if host_full_name != runtime_full_name && (@version_notes ||= {}).fetch(name, true)
        @version_notes[name] = false
        warning "#{host_full_name} is replaced by the static runtime's #{runtime_full_name}"
      end
      if spec.start_with?("specifications/default/")
        # A default gem's files are part of the standard library.
        pack_runtime_gem(name)
        if inner&.start_with?("lib/")
          relative = "lib/ruby/#{@runtime.ruby_api_version}/#{inner.delete_prefix("lib/")}"
          runtime_file = @runtime.lib_file(relative)
          runtime_file ? add(relative, runtime_file) : skip(:not_in_runtime_stdlib, relative)
        end
      else
        pack_runtime_gem(name)
      end
    end

    # Packs a gem from the runtime instead of the host's copy: its spec,
    # its files (without native binaries, which are linked into the
    # runtime), and RubyGems' gem.build_complete marker, without which a
    # gem that declares extensions is not activated.
    def pack_runtime_gem(name)
      return if @runtime_gems.key?(name)

      @runtime_gems[name] = true
      gem_dir = @runtime.gem_dir
      spec = @runtime.gems.fetch(name)
      add("#{gem_dir}/#{spec}", @runtime.dir / gem_dir / spec)
      full_name = File.basename(spec, ".gemspec")
      root = @runtime.dir / gem_dir / "gems" / full_name
      if root.directory?
        root.find do |path|
          next unless path.file?
          next if (NATIVE_EXTENSIONS + HOST_ONLY).include?(path.extname.downcase)

          add("#{gem_dir}/gems/#{full_name}/#{path.relative_path_from(root).to_s}", path)
        end
      end
      if !spec.start_with?("specifications/default/") && gem_declares_extensions?(@runtime.dir / gem_dir / spec)
        marker = "#{gem_dir}/extensions/#{@runtime.gem_platform}/#{@runtime.extension_api_version}/#{full_name}/gem.build_complete"
        @entries[marker] ||= :empty
      end
      verbose "Packing gem #{full_name} from the static runtime"

      # Activating a gem activates its runtime dependencies, so their specs
      # have to be there too (psych needs stringio's, for instance), even
      # when the application never loaded them as gems.
      runtime_dependencies(@runtime.dir / gem_dir / spec).each do |dependency|
        pack_runtime_gem(dependency) if @runtime.gems.key?(dependency)
      end
    end

    def runtime_dependencies(spec_file)
      Gem::Specification.load(spec_file.to_s)&.runtime_dependencies&.map(&:name) || []
    end

    def gem_declares_extensions?(spec_file)
      File.read(spec_file).match?(/\.extensions\s*=\s*\[\s*"/)
    end

    # The standard library's Windows-only Ruby files (win32/registry.rb,
    # win32/resolv.rb): loaded by stdlib code only on Windows (resolv.rb
    # needs win32/resolv to find the hosts file), so a build host other than
    # Windows never sees them loaded. They are small; always pack them.
    def add_windows_stdlib
      dir = @runtime.dir / "lib/ruby" / @runtime.ruby_api_version / "win32"
      return unless dir.directory?

      dir.find do |path|
        next unless path.file? && path.extname == ".rb"

        add(path.relative_path_from(@runtime.dir).to_s, path)
      end
    end

    # What only a Windows executable has: a subsystem, resources, DLLs.
    def check_options_for_os
      return if @runtime.windows?

      runtime = "the #{@runtime.os} runtime #{@runtime.dir}"
      raise "--windows applies to Windows runtimes, not to #{runtime}" if @windowed
      if (@resources || {}).any? { |_, v| v && !(v.respond_to?(:empty?) && v.empty?) }
        raise "--icon and the version-resource options apply to Windows runtimes, not to #{runtime}"
      end
      unless @dlls.empty?
        raise "--runtime-dll: #{runtime} is fully static and cannot load shared libraries"
      end
    end

    # The license texts of what the runtime links in (LICENSES/ of the
    # runtime directory), so that they travel with every executable:
    # `unzip -l app.exe ocran/licenses/*`.
    def add_licenses
      dir = @runtime.dir / "LICENSES"
      return unless dir.directory?

      dir.find do |path|
        add("ocran/licenses/#{path.relative_path_from(dir)}", path) if path.file?
      end
    end

    def finalize
      raise "No script to run was recorded" unless @exec

      check_options_for_os
      add_windows_stdlib if @runtime.windows?
      add_licenses
      work = Dir.mktmpdir("ocran-runtime")
      begin
        if @runtime.sdk&.section_payload?
          write_linked(work)
        else
          relink = !@unsupported_native.empty? || !@dlls.empty?
          executable = relink ? link_extensions(work) : @runtime.executable
          write(executable)
        end
        ship_dlls
      rescue StandardError
        # A copy of the runtime without its archive would look like a
        # finished executable and fail only when run.
        FileUtils.rm_f(@path.to_s)
        raise
      ensure
        remove_work_dir(work)
      end
    end

    # MSYS2's tools on Windows can leave a file named NUL in an extension's
    # build directory, which the Win32 API refuses to delete by its plain
    # path; the \\?\ form bypasses device-name parsing. A directory that
    # still cannot be removed is reported, never a reason to fail the build.
    def remove_work_dir(work)
      FileUtils.rm_rf(work)
      return unless File.exist?(work)

      if Gem.win_platform?
        system("cmd", "/c", "rmdir", "/s", "/q", "\\\\?\\#{File.expand_path(work).tr("/", "\\")}",
               out: File::NULL, err: File::NULL)
      end
      warning "Could not remove the temporary directory #{work}" if File.exist?(work)
    rescue SystemCallError => e
      warning "Could not remove the temporary directory #{work}: #{e.message}"
    end

    # macOS: the archive is written on its own (offsets counted from its
    # start) and linked into the executable as the section __OCRAN,__zip,
    # together with any extensions; the linker lays the executable out and
    # signs it. Appended data would break the code signature. The
    # extensions are built first: building them changes what is packed
    # (build markers, renamed platform gems, dropped foreign binaries).
    def write_linked(work)
      extensions = build_extensions(work)
      archive = File.join(work, "application.zip")
      File.binwrite(archive, ZipWriter.end_of_central_directory(0, 0, 0))
      ZipWriter.append(archive, archive_entries)
      link_runtime(extensions, work, archive: archive, output: @path.to_s)
      File.chmod(0o755, @path.to_s)
    end

    # The C extensions of the application's gems that the runtime does not
    # have: built from the gems' sources against the runtime's SDK and
    # linked into a runtime of this application's own. Returns its path.
    def link_extensions(work)
      link_runtime(build_extensions(work), work)
    end

    # Builds the missing extensions; returns them for #link_runtime.
    def build_extensions(work)
      sdk = @runtime.sdk
      unless sdk
        list = @unsupported_native.map { |name, source| "  #{name} (#{source})" }.join("\n")
        raise "These C extensions are not linked into the static runtime #{@runtime.dir}, which has no SDK " \
              "to link them in, and a C extension cannot be loaded from inside the executable:\n#{list}"
      end
      sdk.check_toolchain!

      @renamed_gems = {}
      by_gem = @unsupported_native.group_by { |_, source| gem_spec_for(source) }
      if (loose = by_gem.delete(nil))
        raise "These C extensions belong to no installed gem, so there is no source to build them " \
              "from for the static runtime:\n#{loose.map { |name, source| "  #{name} (#{source})" }.join("\n")}"
      end

      extensions = by_gem.flat_map do |spec, files|
        if @runtime.gems.key?(spec.name)
          raise "#{spec.full_name} has a C extension the static runtime's own #{spec.name} does not link in " \
                "(#{files.map(&:first).join(", ")})"
        end
        extconfs = spec.extensions
        source_dir = spec.full_gem_path
        if extconfs.empty?
          # A precompiled platform gem. Build from the source gem of the same
          # version (a platform gem may leave sources out: nokogiri's lacks
          # its gumbo parser), or else from the sources it carries.
          source_dir = source_gem_dir(spec) || spec.full_gem_path
          extconfs = Dir.glob("ext/**/extconf.rb", base: source_dir).sort
          if extconfs.empty?
            raise "#{spec.full_name} is a precompiled gem for #{spec.platform} without its C source: install " \
                  "the source gem (gem install #{spec.name} --platform ruby)"
          end
          use_as_ruby_platform_gem(spec, work)
        end
        built = extconfs.map do |extconf|
          ext_dir = File.join(source_dir, File.dirname(extconf))
          unless File.file?(File.join(source_dir, extconf))
            raise "#{spec.full_name}: #{extconf} is not installed, so its C extension cannot be built"
          end
          say "Building the C extension #{extconf} of #{spec.full_name} for the static runtime"
          sdk.build_extension(ext_dir, File.join(work, spec.full_name, File.dirname(extconf)),
                              "--with-opt-dir=#{sdk.dir / "deps"}", *sdk.extconf_args(spec.name))
        end
        files.each do |name, _|
          stem = name.sub(/\.(so|bundle)\z/, "")
          # A precompiled gem keeps it in a Ruby-version directory
          # (lib/nokogiri/4.0/nokogiri.so for the feature nokogiri/nokogiri).
          next if built.any? { |ext| stem.end_with?("/#{ext.feature}") || File.basename(stem) == File.basename(ext.feature) }

          raise "Building #{spec.full_name} for the static runtime did not provide #{name} " \
                "(it built #{built.map(&:feature).join(", ")})"
        end
        mark_extensions_built(spec, files)
        built
      end
    end

    def link_runtime(extensions, work, archive: nil, output: nil)
      sdk = @runtime.sdk
      executable = output || File.join(work, "ocran-runtime.exe")
      say "Linking #{extensions.map(&:feature).join(", ")} into the static runtime" unless extensions.empty?
      say "Linking against the DLL builds of #{@dlls.join(", ")}" unless @dlls.empty?
      say "Linking the application archive into the executable (section __OCRAN,__zip)" if archive
      sdk.link(extensions, executable, dlls: @dlls, archive: archive)
      @dll_files = sdk.dll_files(@dlls)
      Pathname(executable)
    end

    # The unpacked source gem (platform "ruby") of the version of a
    # precompiled +spec+, fetched from the configured gem sources into
    # ~/.cache/ocran/gems; nil when it cannot be fetched.
    def source_gem_dir(spec)
      cache = File.join(ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache"), "ocran", "gems")
      dir = File.join(cache, "#{spec.name}-#{spec.version}")
      return dir if File.directory?(dir)

      say "Fetching the source gem of #{spec.name} #{spec.version}: the precompiled #{spec.full_name} is " \
          "built for #{spec.platform}"
      require "rubygems/spec_fetcher"
      require "rubygems/package"
      tuples, = Gem::SpecFetcher.fetcher.spec_for_dependency(Gem::Dependency.new(spec.name, spec.version.to_s))
      remote, source = tuples.find { |s, _| s.platform.to_s == Gem::Platform::RUBY }
      raise "no source gem of #{spec.name} #{spec.version}" unless remote

      Dir.mktmpdir do |tmp|
        gem_file = source.download(remote, tmp)
        FileUtils.mkdir_p(cache)
        Gem::Package.new(gem_file).extract_files("#{dir}.tmp")
        File.rename("#{dir}.tmp", dir)
      end
      dir
    rescue StandardError => e
      warning "Could not fetch the source gem of #{spec.name} #{spec.version} (#{e.message}); " \
              "building from the sources #{spec.full_name} includes"
      FileUtils.rm_rf("#{dir}.tmp") if dir
      nil
    end

    # The packed copy of a precompiled platform gem (nokogiri-1.19.4-x86_64-
    # linux-gnu) becomes a platform "ruby" gem (nokogiri-1.19.4): RubyGems
    # on Windows ignores a spec for another platform. Its spec is rewritten
    # and its files are moved to the directory the new name implies.
    def use_as_ruby_platform_gem(spec, work)
      ruby_spec = spec.dup
      ruby_spec.platform = Gem::Platform::RUBY
      return if ruby_spec.full_name == spec.full_name

      spec_file = File.join(work, "#{ruby_spec.full_name}.gemspec")
      File.write(spec_file, ruby_spec.to_ruby)
      old, new = spec.full_name, ruby_spec.full_name
      @entries = @entries.to_h do |name, source|
        if name.match?(%r{(\A|/)specifications/#{Regexp.escape(old)}\.gemspec\z})
          [name.sub("#{old}.gemspec", "#{new}.gemspec"), Pathname(spec_file)]
        else
          [name.sub(%r{(\A|/)(gems|extensions/[^/]+/[^/]+)/#{Regexp.escape(old)}(/|\z)}) { "#{$1}#{$2}/#{new}#{$3}" }, source]
        end
      end
      @renamed_gems[old] = new
      drop_foreign_binaries(new)
    end

    NATIVE_MAGIC = ["\x7FELF".b, "MZ".b, "\xCF\xFA\xED\xFE".b, "\xCE\xFA\xED\xFE".b, "\xCA\xFE\xBA\xBE".b].freeze

    # A precompiled gem carries binaries for its platform - libraries and
    # programs (tiny_tds: ports/x86_64-linux-gnu/lib/libsybdb.so.5,
    # bin/tsql) - that are of no use on Windows; dropped by content, since
    # their names say little.
    def drop_foreign_binaries(full_name)
      @entries.reject! do |name, source|
        next false unless name.match?(%r{(\A|/)gems/#{Regexp.escape(full_name)}/}) && source.is_a?(Pathname)

        head = File.binread(source.to_s, 4) || ""
        native = NATIVE_MAGIC.any? { |magic| head.start_with?(magic) }
        if native
          skip(:foreign_binary, name)
          @data_size -= File.size(source.to_s)
        end
        native
      end
    end

    # --runtime-dll: the DLLs go next to the executable, where Windows looks
    # for them first.
    def ship_dlls
      (@dll_files || []).each do |dll|
        target = @path.dirname / dll.basename
        FileUtils.cp(dll.to_s, target.to_s)
        @shipped_dlls << target
      end
    end

    # The installed gem a C extension file of the build host belongs to.
    def gem_spec_for(source)
      path = File.expand_path(source.to_s)
      specs = Gem.loaded_specs.values + Gem::Specification.to_a
      specs.find do |spec|
        path.start_with?("#{spec.full_gem_path}/") ||
          (!spec.extensions.empty? && path.start_with?("#{spec.extension_dir}/"))
      end
    end

    # RubyGems activates a gem that declares extensions only when their
    # gem.build_complete marker exists for the platform it runs on - the
    # runtime's, not the build host's.
    def mark_extensions_built(spec, files)
      return if @renamed_gems.key?(spec.full_name) # a platform-"ruby" copy declares no extensions

      files.each do |name, _|
        base = name[%r{\A(.*?)/?(?:gems|extensions/[^/]+/[^/]+)/#{Regexp.escape(spec.full_name)}/}, 1] or next
        prefix = base.empty? ? "" : "#{base}/"
        @entries["#{prefix}extensions/#{@runtime.gem_platform}/#{@runtime.extension_api_version}/#{spec.full_name}/gem.build_complete"] ||= :empty
      end
    end

    def write(executable)
      @executable = Pathname(executable)
      FileUtils.cp(@executable.to_s, @path.to_s)
      File.chmod(0o755, @path.to_s)
      set_gui_subsystem if @windowed
      apply_resources

      File.open(@path.to_s, "ab") do |io|
        # An empty archive at the end of the runtime, so that ZipWriter
        # writes the entries right after it with offsets counted from the
        # start of the file - which is what makes `unzip -l app.exe` work.
        io.write(ZipWriter.end_of_central_directory(0, 0, io.size))
      end
      ZipWriter.append(@path.to_s, archive_entries)
    end

    def archive_entries
      boot = File.binread(BOOT_SCRIPT)
      config = config_source
      entries = [
        zip_entry("ocran/boot.rb", data: boot),
        zip_entry("ocran/config.rb", data: config),
      ]
      files = @entries.reject { |name, _| name.end_with?("/") }
      # Every directory gets an entry of its own, with the fixed time:
      # ZipWriter would otherwise add the missing ones with the current time.
      dirs = (@entries.keys.select { |name| name.end_with?("/") } +
              (files.keys + ["ocran/"]).flat_map { |name| parent_dirs(name) }).uniq.sort
      dirs.each { |dir| entries << zip_entry(dir) }
      files.sort.each do |name, source|
        entries << zip_entry(name, **(source == :empty ? { data: "" } : { source: source.to_s }))
      end
      entries << zip_entry("ocran/manifest.sha256", data: manifest(boot, config, files))
    end

    def parent_dirs(name)
      parts = name.split("/")[0...-1]
      parts.each_index.map { |i| "#{parts[0..i].join("/")}/" }
    end

    # Entries carry a fixed time, so that packing the same inputs twice
    # gives the same bytes (SOURCE_DATE_EPOCH, as other reproducible-build
    # tools use, else 2000-01-01).
    def zip_entry(name, **kw)
      @mtime ||= Time.at(Integer(ENV.fetch("SOURCE_DATE_EPOCH", "946684800"))).utc
      ZipWriter::Entry.new(name: name, mtime: @mtime, **kw)
    end

    # SHA-256 of the runtime and of every packed file, for auditing:
    # `unzip -p app.exe ocran/manifest.sha256` lists exactly what the
    # executable contains.
    def manifest(boot, config, files)
      runtime =
        if @executable.nil? # macOS: linked together with this archive
          "linked together with this archive, Ruby #{@runtime.ruby_version} #{@runtime.arch}"
        else
          name = @executable == @runtime.executable ? @runtime.executable.basename.to_s : "linked for this application"
          "#{name}, Ruby #{@runtime.ruby_version} #{@runtime.arch} #{Digest::SHA256.file(@executable.to_s).hexdigest}"
        end
      lines = ["# ocran static runtime application manifest (sha256sum format)",
               "# runtime: #{runtime}",
               "#{Digest::SHA256.hexdigest(boot)}  ocran/boot.rb",
               "#{Digest::SHA256.hexdigest(config)}  ocran/config.rb"]
      files.sort.each do |name, source|
        digest = source == :empty ? Digest::SHA256.hexdigest("") : Digest::SHA256.file(source.to_s).hexdigest
        lines << "#{digest}  #{name}"
      end
      lines.join("\n") + "\n"
    end

    # ocran/config.rb: what boot.rb needs to start the application. Paths
    # that Direction gives relative to the extraction root (|/...) become
    # <ROOT>/..., and lists are joined with the separator of the target
    # (";" on Windows, ":" elsewhere), whatever the build host uses.
    def config_source
      env = @env.dup
      rubylib = split_paths(env.delete("RUBYLIB"))
      rubyopt = env["RUBYOPT"].to_s
      includes, requires, unsupported = ZipPayloadBuilder.parse_rubyopt(rubyopt)
      unsupported.each { |flag| warning "RUBYOPT #{flag} cannot be applied by the static runtime; only -I and -r are" }

      load_path = rubylib.filter_map { |dir| relative_to_root(dir) }
                         .reject { |dir| dir.start_with?("lib/ruby/") } # the runtime's own, below
      load_path += @runtime.load_path
      env = env.to_h do |name, value|
        if %w[GEM_HOME GEM_PATH].include?(name)
          [name, split_paths(value).map { |dir| root_path(dir) }.join(@runtime.windows? ? ";" : ":")]
        else
          [name, root_path(value)]
        end
      end

      config = {
        main: @exec[0],
        argv: @exec[1].map { |arg| root_path(arg) },
        load_path: load_path.uniq,
        env: env,
        rubyopt_includes: includes.map { |dir| root_path(dir) },
        rubyopt_requires: requires.map { |lib| root_path(lib) },
        chdir_exe_dir: @chdir,
        rubygems: true,
        debug: @debug_mode,
      }
      "# Generated by OCRAN: settings for ocran/boot.rb.\n#{config.inspect}\n"
    end

    def split_paths(value)
      value.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
    end

    # Archive-relative path for an extraction-root path, or nil when it
    # lies outside the application.
    def relative_to_root(path)
      path = path.to_s.tr("\\", "/")
      root = EXTRACT_ROOT.to_s
      return "" if path == root
      return nil unless path.start_with?("#{root}/")

      path.delete_prefix("#{root}/")
    end

    def root_path(value)
      value.to_s.gsub(/#{Regexp.escape(EXTRACT_ROOT.to_s)}(?=\/|\z)/, ROOT)
    end

    # --icon and the version-resource options, written into the copy of the
    # runtime before the archive is appended (pure Ruby, any build host).
    def apply_resources
      r = (@resources || {}).reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      return if r.empty?

      require_relative "pe_resources"
      PeResources.update(@path.to_s) do |pe|
        if r[:icon_path]
          raise "Icon file #{r[:icon_path]} not found" unless File.file?(r[:icon_path])

          pe.set_icon(File.binread(r[:icon_path]))
        end
        if r[:version_strings] || r[:file_version] || r[:product_version]
          strings = (r[:version_strings] || {}).to_h { |k, v| [k.to_s, v] }
          strings["FileVersion"] = r[:file_version] if r[:file_version]
          strings["ProductVersion"] = r[:product_version] if r[:product_version]
          pe.set_version_info(EdResource::Build.version_info(
            strings: strings,
            file_version: r[:file_version] || strings["FileVersion"] || "0.0.0.0",
            product_version: r[:product_version] || strings["ProductVersion"] || "0.0.0.0"
          ))
        end
        if r[:application_manifest] || r[:execution_level]
          xml = r[:application_manifest] ? File.read(r[:application_manifest], encoding: "UTF-8") : nil
          xml ||= pe.manifest&.dup&.force_encoding(Encoding::UTF_8) || EdResource::MANIFEST_TEMPLATE
          if (level = r[:execution_level])
            raise "Invalid requested execution level: #{level}" unless EdResource::EXECUTION_LEVELS.include?(level)

            xml = xml.sub(/level="[^"]*"/, %(level="#{level}"))
          end
          pe.set_manifest(xml)
        end
        pe.set_strings(r[:resource_strings]) if r[:resource_strings]
      end
    end

    # --windows: the runtime is a console program; switching the PE
    # subsystem to GUI is all rubyw.exe does differently at the image level.
    def set_gui_subsystem
      File.open(@path.to_s, "r+b") do |io|
        io.seek(0x3c)
        pe = io.read(4).unpack1("V")
        io.seek(pe + 24 + 68) # optional header Subsystem, same in PE32 and PE32+
        io.write([2].pack("v")) # IMAGE_SUBSYSTEM_WINDOWS_GUI
      end
    end
  end
end
