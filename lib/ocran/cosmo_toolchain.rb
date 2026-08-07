# frozen_string_literal: true
require "digest"
require "fileutils"
require "tmpdir"

module Ocran
  # Builds the launcher stub from the C sources in src/ with a
  # Cosmopolitan Libc toolchain (cosmocc, https://cosmo.zip) at packaging
  # time, producing an Actually Portable Executable (APE) stub that is
  # used instead of the pre-built native stub shipped with the gem.
  #
  # Activated with the --cosmo (alias: --cosmo-toolchain) command line
  # option. See docs/cosmocc-port-plan.md for background and caveats.
  module CosmoToolchain
    # Stub C sources shipped with the gem (also included in the binary
    # platform gems specifically so this feature works from an installed gem).
    SRC_DIR = File.expand_path("../../src", __dir__)

    module_function

    # Resolves the path given on the command line to the cosmocc compiler
    # driver. Accepts either the cosmocc executable itself, the toolchain
    # installation directory (containing bin/cosmocc), or its bin directory.
    # Returns the absolute path to cosmocc; raises with a clear message
    # when nothing usable is found.
    def resolve_cc(path)
      if path.nil? || path.to_s.empty?
        raise "--cosmo requires a path to a cosmocc toolchain (the cosmocc executable or its installation directory)"
      end

      path = File.expand_path(path.to_s)

      candidates =
        if File.directory?(path)
          [File.join(path, "bin", "cosmocc"), File.join(path, "cosmocc")]
        else
          [path]
        end

      cc = candidates.find { |c| File.file?(c) }
      unless cc
        raise "cosmocc not found at #{path} (expected the cosmocc executable itself, or a toolchain directory containing bin/cosmocc)"
      end
      unless File.executable?(cc)
        raise "cosmocc found at #{cc} but it is not executable"
      end
      cc
    end

    # Compiles the stub sources with the given cosmocc and returns the
    # path to the resulting APE stub binary. Results are cached in the
    # user cache directory, keyed on the toolchain and the stub sources,
    # so repeated packaging runs do not recompile. On compile failure the
    # compiler output is included in the raised error.
    def build_stub(cc)
      if Gem.win_platform?
        raise "--cosmo is not supported when building on Windows (build the APE stub on a Linux/macOS host)"
      end
      unless system("command -v make > /dev/null 2>&1")
        raise "make not found in PATH (required to build the stub with cosmocc)"
      end
      unless File.directory?(SRC_DIR)
        raise "stub sources not found at #{SRC_DIR} (cannot build with cosmocc)"
      end

      cached = File.join(cache_dir, "stub-#{cache_key(cc)}")
      return cached if File.file?(cached)

      Dir.mktmpdir("ocran-cosmo") do |tmp|
        build_dir = File.join(tmp, "src")
        FileUtils.cp_r(SRC_DIR, build_dir)
        log = File.join(tmp, "make.log")
        # A development checkout may contain native build artifacts
        # (.o files, stub) that cp_r copied along — clean them so the
        # stub is fully rebuilt with cosmocc.
        system("make", "-C", build_dir, "clean", { [:out, :err] => IO::NULL })
        ok = system("make", "-C", build_dir, "stub", "CC=#{cc}",
                    { [:out, :err] => log })
        unless ok
          output = File.exist?(log) ? File.read(log) : "(no build output captured)"
          raise "Failed to build the stub with cosmocc (make -C src stub CC=#{cc}):\n#{output}"
        end
        FileUtils.mkdir_p(File.dirname(cached))
        FileUtils.cp(File.join(build_dir, "stub"), cached)
        File.chmod(0755, cached)
      end
      cached
    end

    # Cache key covering the toolchain (path, mtime, size — so an updated
    # toolchain at the same path recompiles) and every stub source file.
    def cache_key(cc)
      digest = Digest::SHA256.new
      stat = File.stat(cc)
      digest << cc << stat.mtime.to_i.to_s << stat.size.to_s
      Dir.glob("**/*", base: SRC_DIR).sort.each do |rel|
        abs = File.join(SRC_DIR, rel)
        next unless File.file?(abs)
        digest << rel << File.binread(abs)
      end
      digest.hexdigest[0, 16]
    end

    def cache_dir
      base = ENV["XDG_CACHE_HOME"]
      base = File.join(Dir.home, ".cache") if base.nil? || base.empty?
      File.join(base, "ocran")
    rescue ArgumentError # Dir.home unavailable (no HOME)
      File.join(Dir.tmpdir, "ocran-cache")
    end
  end
end
