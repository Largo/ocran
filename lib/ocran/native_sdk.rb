# frozen_string_literal: true
require "pathname"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"

module Ocran
  # The SDK part of a native runtime (<runtime>/sdk, written by
  # native/make-sdk.rb): what is needed to link the runtime again with more
  # C extensions statically linked in - its link inputs and link command
  # (link.args), Ruby's headers, the runtime's rbconfig.rb with the
  # <arch>-fake.rb Ruby's cross builds use to describe the target, and the
  # gem extensions already linked in (exts/*.line).
  #
  # Linking needs a compiler for the runtime's target on the build host. For
  # a MinGW runtime (toolchain "gcc" in sdk.json): the one link.args names
  # (e.g. x86_64-w64-mingw32ucrt-gcc on Linux), or OCRAN_NATIVE_CC (e.g. gcc
  # from RubyInstaller's MSYS2 on Windows). For an mswin runtime ("msvc"):
  # cl and nmake of Visual Studio (Build Tools), from a developer prompt.
  class NativeSdk
    BUILD_STATIC_EXT = File.expand_path("native/build_static_ext.rb", __dir__)

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
      raise "#{@dir} is not a native runtime SDK (no link.args)" unless (@dir / "link.args").file?

      info = (@dir / "sdk.json").file? ? JSON.parse((@dir / "sdk.json").read) : {}
      @toolchain = info.fetch("toolchain", "gcc")
    end

    def msvc? = @toolchain == "msvc"

    def link_args = (@dir / "link.args").read.lines(chomp: true).map { |a| a.gsub("@SDK@", @dir.to_s) }

    # The C compiler driver of the target.
    def cc
      return "cl" if msvc?

      env = ENV["OCRAN_NATIVE_CC"]
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
      return if status.success? && out.include?("mingw32")

      raise "#{cc} #{status.success? ? "does not target Windows (#{out.strip})" : "did not run"}; " \
            "set OCRAN_NATIVE_CC to a MinGW-w64 UCRT C compiler (on Linux: gcc-mingw-w64-ucrt64, " \
            "on Windows: RubyInstaller's MSYS2, e.g. `ridk exec` or ucrt64/bin/gcc.exe)"
    rescue SystemCallError
      raise "#{cc} not found; set OCRAN_NATIVE_CC to a MinGW-w64 UCRT C compiler " \
            "(on Linux: gcc-mingw-w64-ucrt64, on Windows: RubyInstaller's MSYS2)"
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
      # The SDK's rbconfig.rb is found first on the load path; a MinGW SDK
      # also has Ruby's <arch>-fake.rb, which makes any Ruby pose as the
      # runtime's (an mswin build host runs the runtime's own revision).
      fake = Dir[(@dir / "*-fake.rb").to_s].first
      env = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil,
              "OCRAN_NATIVE_CC" => msvc? ? nil : ENV["OCRAN_NATIVE_CC"] || (cc == link_args.first ? nil : cc) }
      cmd = [RbConfig.ruby, "--disable=gems", "-I", @dir.to_s, *(fake ? ["-r", fake] : []), BUILD_STATIC_EXT,
             (@dir / "include").to_s, (@dir / "include" / @arch).to_s, ext_dir.to_s, work_dir.to_s, *extconf_args]
      out, status = Open3.capture2e(env, *cmd)
      unless status.success?
        raise "Building the C extension in #{ext_dir} for the native runtime failed:\n#{out.lines.last(25).join}"
      end

      Extension.parse(out.lines.last, @dir)
    end

    # Links the runtime with the given extensions registered in addition to
    # those it already has, into +output+.
    def link(extensions, output)
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

        extra = [obj] + all.flat_map { |ext| [ext.archive, *ext.libs] }
        args = link_args
        args[0] = cc
        cmd = args.flat_map { |a| a == "@EXTRA@" ? extra : [a.gsub("@OUTPUT@", output.to_s)] }
        cmd += ["-o", output.to_s] unless args.any? { |a| a.include?("@OUTPUT@") }
        run(*cmd)
      end
      run(cc.sub(/gcc(\.exe)?\z/) { "strip#{$1}" }, output.to_s) unless msvc?
      output
    end

    private

    def exts_source(extensions)
      <<~C
        /* generated by ocran (Ocran::NativeSdk) */
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
