# frozen_string_literal: true
require "pathname"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require_relative "pe_imports"

module Ocran
  # The SDK part of a static runtime (<runtime>/sdk, written by
  # runtime/make-sdk.rb): what is needed to link the runtime again with more
  # C extensions statically linked in - its link inputs and link command
  # (link.args), Ruby's headers, the runtime's rbconfig.rb with the
  # <arch>-fake.rb Ruby's cross builds use to describe the target, and the
  # gem extensions already linked in (exts/*.line).
  #
  # Linking needs a compiler for the runtime's target on the build host. For
  # a MinGW runtime (toolchain "gcc" in sdk.json): the one link.args names
  # (e.g. x86_64-w64-mingw32ucrt-gcc on Linux), or OCRAN_RUNTIME_CC (e.g. gcc
  # from RubyInstaller's MSYS2 on Windows). For an mswin runtime ("msvc"):
  # cl and nmake of Visual Studio (Build Tools), from a developer prompt.
  class RuntimeSdk
    BUILD_STATIC_EXT = File.expand_path("static_runtime/build_static_ext.rb", __dir__)

    # One statically built extension: the feature it provides ("bcrypt_ext"),
    # its Init function, the static library and the libraries it links with.
    Extension = Struct.new(:feature, :init, :archive, :libs) do
      def self.parse(line, base)
        feature, init, archive, libs = line.strip.split(" ", 4)
        raise "bad extension line #{line.inspect}" unless feature&.match?(%r{\A[\w/.-]+\z}) && init&.match?(/\A\w+\z/)

        new(feature, init, File.expand_path(archive.sub("@SDK@", base.to_s)), libs.to_s.split(","))
      end
    end

    attr_reader :dir, :arch, :toolchain

    def initialize(dir, arch:)
      @dir = Pathname(dir)
      @arch = arch
      raise "#{@dir} is not a static runtime SDK (no link.args)" unless (@dir / "link.args").file?

      @info = (@dir / "sdk.json").file? ? JSON.parse((@dir / "sdk.json").read) : {}
      @toolchain = @info.fetch("toolchain", "gcc")
    end

    # Libraries available as DLLs instead of linked in (--runtime-dll):
    # name ("sybdb") => { "dll" => ..., "import" => ... }, relative to the SDK.
    def dlls = @info.fetch("dlls", {})

    # extconf.rb options for gems whose C library the SDK provides, so that
    # extconf.rb uses it instead of downloading and building its own.
    GEM_EXTCONF_ARGS = {
      "nokogiri" => ["--use-system-libraries"],
      "tiny_tds" => ["--with-freetds-dir=@SDK_DEPS@"],
    }.freeze

    def extconf_args(gem_name)
      (GEM_EXTCONF_ARGS[gem_name] || []).map { |a| a.gsub("@SDK_DEPS@", (@dir / "deps").to_s) }
    end

    def msvc? = @toolchain == "msvc"

    def link_args = (@dir / "link.args").read.lines(chomp: true).map { |a| a.gsub("@SDK@", @dir.to_s) }

    # The C compiler driver of the target.
    def cc
      return "cl" if msvc?

      env = ENV["OCRAN_RUNTIME_CC"]
      env && !env.empty? ? env : link_args.first
    end

    # The gem extensions already linked into the runtime.
    def base_extensions
      Dir[(@dir / "exts/*.line").to_s].sort.map { |f| Extension.parse(File.read(f), @dir) }
    end

    # Fails early, with a hint, when the build host has no compiler for the
    # runtime's target.
    def check_toolchain!
      return check_msvc! if msvc?

      out, status = Open3.capture2e(cc, "-dumpmachine")
      expected = @info["dumpmachine"]
      return if status.success? && (expected.nil? || out.include?(expected))

      raise "#{cc} #{status.success? ? "does not target #{expected} (#{out.strip})" : "did not run"}; " \
            "set OCRAN_RUNTIME_CC to #{toolchain_hint}"
    rescue SystemCallError
      raise "#{cc} not found; set OCRAN_RUNTIME_CC to #{toolchain_hint}"
    end

    def toolchain_hint
      if @info.fetch("target_os", "mingw32").start_with?("mingw")
        "a MinGW-w64 UCRT C compiler (on Linux: gcc-mingw-w64-ucrt64, on Windows: RubyInstaller's " \
          "MSYS2, e.g. ucrt64/bin/gcc.exe)"
      else
        "a musl C compiler (musl-gcc from musl-tools)"
      end
    end

    def check_msvc!
      %w[cl nmake].each do |tool|
        Open3.capture2e(tool, "-?")
      rescue SystemCallError
        raise "#{tool} not found: building C extensions for an mswin runtime needs Visual Studio " \
              "(Build Tools); run ocran from a \"x64 Native Tools\" developer prompt"
      end
    end

    # Compiles the C extension in +ext_dir+ (a gem's ext/<name>/, with its
    # extconf.rb) to a static library under +work_dir+.
    def build_extension(ext_dir, work_dir, *extconf_args)
      pkgconfig = File.join(work_dir.to_s + ".pkgconfig")
      FileUtils.mkdir_p(pkgconfig)
      Dir[(@dir / "deps/lib/pkgconfig/*.pc").to_s].each do |pc|
        File.write(File.join(pkgconfig, File.basename(pc)), File.read(pc).gsub("@SDK_DEPS@", (@dir / "deps").to_s))
      end
      # The SDK's rbconfig.rb is found first on the load path; a MinGW SDK
      # also has Ruby's <arch>-fake.rb, which makes any Ruby pose as the
      # runtime's (an mswin build host runs the runtime's own revision).
      fake = Dir[(@dir / "*-fake.rb").to_s].first
      env = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil,
              "OCRAN_RUNTIME_CC" => msvc? ? nil : ENV["OCRAN_RUNTIME_CC"] || (cc == link_args.first ? nil : cc),
              "OCRAN_RUNTIME_LIBS" => @info.fetch("libs", []).join(" "),
              "OCRAN_RUNTIME_CPPFLAGS" => @info.fetch("cppflags", []).join(" "),
              "PKG_CONFIG_LIBDIR" => pkgconfig, "PKG_CONFIG_PATH" => "",
              # Build-time gems extconf.rb uses (nokogiri: mini_portile2):
              # the build host's, which the target's RbConfig would hide.
              "GEM_HOME" => Gem.dir, "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR) }
      cmd = [RbConfig.ruby, "--disable=gems", "-I", @dir.to_s, *(fake ? ["-r", fake] : []), BUILD_STATIC_EXT,
             (@dir / "include").to_s, (@dir / "include" / @arch).to_s, ext_dir.to_s, work_dir.to_s, *extconf_args]
      out, status = Open3.capture2e(env, *cmd)
      unless status.success?
        raise "Building the C extension in #{ext_dir} for the static runtime failed:\n#{out.lines.last(25).join}"
      end

      Extension.parse(out.lines.last, @dir)
    end

    # Links the runtime with the given extensions registered in addition to
    # those it already has, into +output+. Libraries named in +dlls+ are
    # linked against their DLL instead of statically (see #dll_files).
    def link(extensions, output, dlls: [])
      unknown = dlls - self.dlls.keys
      unless unknown.empty?
        raise "No DLL build of #{unknown.join(", ")} in #{@dir} (available: #{self.dlls.keys.join(", ")})"
      end
      as_dll = dlls.to_h { |name| ["-l#{name}", (@dir / self.dlls[name]["import"]).to_s] }
      all = base_extensions + extensions
      Dir.mktmpdir do |tmp|
        src = File.join(tmp, "ocran_exts.c")
        File.write(src, exts_source(all))
        obj = File.join(tmp, msvc? ? "ocran_exts.obj" : "ocran_exts.o")
        if msvc?
          run("cl", "-nologo", "-MT", "-O2", "-c", src, "-Fo#{obj}")
        else
          run(cc, "-O2", "-c", src, "-o", obj)
        end

        extra = [obj] + all.flat_map { |ext| [ext.archive, *ext.libs] } + @info.fetch("libs", [])
        args = link_args
        args[0] = cc
        cmd = args.flat_map { |a| a == "@EXTRA@" ? extra : [a.gsub("@OUTPUT@", output.to_s)] }
        cmd = cmd.map { |a| as_dll.fetch(a, a) }
        cmd += ["-o", output.to_s] unless args.any? { |a| a.include?("@OUTPUT@") }
        run(*cmd)
      end
      run(@info["strip"] || cc.sub(/gcc(\.exe)?\z/) { "strip#{$1}" }, output.to_s) unless msvc?
      output
    end

    # The DLL files to ship next to the executable for +dlls+: each named
    # library's DLL and the SDK DLLs it imports in turn (libsybdb-5.dll
    # needs libiconv-2.dll).
    def dll_files(dlls)
      by_file = self.dlls.values.to_h { |d| [File.basename(d["dll"]).downcase, @dir / d["dll"]] }
      queue = dlls.map { |name| @dir / self.dlls.fetch(name)["dll"] }
      found = {}
      until queue.empty?
        dll = queue.shift
        next if found[dll.basename.to_s.downcase]

        found[dll.basename.to_s.downcase] = dll
        PEImports.dll_names(dll.to_s).each { |name| queue << by_file[name.downcase] if by_file[name.downcase] }
      end
      found.values
    end

    private

    def exts_source(extensions)
      <<~C
        /* generated by ocran (Ocran::RuntimeSdk) */
        void ruby_init_ext(const char *name, void (*init)(void));
        #{extensions.map { |e| "extern void #{e.init}(void);" }.join("\n")}
        void ocran_init_extra_exts(void)
        {
        #{extensions.map { |e| "    ruby_init_ext(\"#{e.feature}.so\", #{e.init});" }.join("\n")}
        }
      C
    end

    def run(*cmd)
      out, status = Open3.capture2e(*cmd)
      raise "#{cmd.first} failed:\n#{out.lines.last(25).join}" unless status.success?

      out
    end
  end
end
