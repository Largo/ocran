# frozen_string_literal: true
#
# NOTE: no file-scope require of digest/fileutils/tmpdir. This file is
# loaded while the command line is parsed, i.e. before OCRAN snapshots
# $LOADED_FEATURES for dependency detection (see
# Ocran::Option#load_cosmo_toolchain); anything required here would end up
# in that diff and be packed into the user's application. The three
# libraries are only needed at build time - after the snapshot - so they
# are required inside the methods that use them.

module Ocran
  # Builds the launcher stub from the C sources in src/ with a
  # Cosmopolitan Libc toolchain (cosmocc, https://cosmo.zip) at packaging
  # time, producing an Actually Portable Executable (APE) stub that is
  # used instead of the pre-built native stub shipped with the gem.
  #
  # The toolchain is named explicitly by --cosmo (alias: --cosmo-toolchain)
  # or, when only --cosmo-ruby is given, discovered on the build host (see
  # find_cc). See docs/cosmocc-port-plan.md for background and caveats.
  module CosmoToolchain
    # Stub C sources shipped with the gem (also included in the binary
    # platform gems specifically so this feature works from an installed gem).
    SRC_DIR = File.expand_path("../../src", __dir__)

    # Every APE binary starts with this MZ/shell-script polyglot magic.
    APE_MAGIC = "MZqFpD"

    # Name of the environment variable a CosmoRuby build honors to switch
    # OFF running an embedded /zip/main.rb, i.e. to behave as an ordinary
    # interpreter (useful for inspecting a packaged application). Its
    # presence in the binary is what marks the build as one that runs an
    # embedded main script at all, which is the capability the
    # compiler-free ZIP packaging mode is built on - a build without it
    # would ignore the injected main.rb and try to run the first argument
    # as a script instead.
    ZIP_MAIN_MARKER = "COSMORUBY_NO_ZIP_MAIN"

    # How much of the binary is read at a time when scanning for the
    # marker. The marker sits in the interpreter's code, not in its ZIP
    # store, so the whole file may have to be read; it is a ~20 MB
    # sequential scan, a few tens of milliseconds.
    SCAN_CHUNK_SIZE = 1 << 20

    # Environment variable naming a cosmocc toolchain (the cosmocc
    # executable or its installation directory), checked before PATH.
    COSMOCC_ENV = "COSMOCC"

    # Where a cosmocc toolchain is conventionally unpacked, searched when
    # neither COSMOCC nor PATH names one. Cosmopolitan's own quick
    # start unzips cosmocc.zip into a directory named "cosmocc" and adds
    # its bin/ to PATH; "~" is the user's home directory and "*" matches
    # version directories of vendored toolchains (the layout the
    # cosmo-adjacent projects use, e.g. .cosmocc/3.9.2/bin/cosmocc). The
    # cosmopolitan monorepo checkout at /opt/cosmo is covered too.
    CONVENTIONAL_CC_PATHS = [
      "~/.cosmocc/*/bin/cosmocc",
      "~/.cosmocc/bin/cosmocc",
      "~/cosmocc/*/bin/cosmocc",
      "~/cosmocc/bin/cosmocc",
      "/opt/cosmocc/*/bin/cosmocc",
      "/opt/cosmocc/bin/cosmocc",
      "/opt/cosmo/bin/cosmocc",
      "/usr/local/cosmocc/bin/cosmocc",
    ].freeze

    module_function

    # Resolves the path given to --cosmo-ruby to a cosmopolitan Ruby
    # executable (conventionally ruby.com). Validates that the file
    # exists and is an APE binary; returns the absolute path.
    def resolve_ruby(path)
      if path.nil? || path.to_s.empty?
        raise "--cosmo-ruby requires a path to a cosmopolitan Ruby executable (e.g. ruby.com)"
      end

      path = File.expand_path(path.to_s)
      unless File.file?(path)
        raise "cosmopolitan Ruby not found at #{path}"
      end

      magic = File.binread(path, APE_MAGIC.bytesize)
      unless magic == APE_MAGIC
        raise "#{path} does not look like an APE (Actually Portable Executable) — expected the #{APE_MAGIC.inspect} magic (got #{magic.inspect}); --cosmo-ruby needs a cosmopolitan-built ruby.com"
      end

      path
    end

    # True when the given cosmopolitan Ruby runs an embedded /zip/main.rb
    # on startup. Such a build can be packaged without any compiler: the
    # application is injected into the binary's own ZIP store and the
    # binary runs it (see ZipPayloadBuilder). Builds without the hook need
    # the APE launcher stub, and therefore cosmocc.
    #
    # Detected by scanning for the name of the opt-out environment
    # variable, which only a build implementing the hook contains. The
    # alternative - copying the 20 MB binary, injecting a probe script and
    # running it - is an order of magnitude more expensive for the same
    # answer, and the scan cannot produce a false positive on a build that
    # never looks at the variable.
    def zip_main_support?(ruby)
      marker = ZIP_MAIN_MARKER.b
      overlap = marker.bytesize - 1
      previous = "".b

      File.open(ruby, "rb") do |io|
        while (chunk = io.read(SCAN_CHUNK_SIZE))
          return true if (previous + chunk).include?(marker)

          previous = chunk.byteslice(-overlap, overlap) || chunk
        end
      end
      false
    end

    # Runs the given cosmopolitan Ruby once on the build host and returns
    # { version:, default_gem_dir:, gem_names: }. The version is used to
    # warn about build-host/payload skew; the default gem dir (inside the
    # APE's /zip store) must be appended to GEM_PATH in the package,
    # because setting GEM_PATH stops RubyGems from scanning its
    # compiled-in default directory, where the APE's bundled gems live;
    # the gem names are the default/bundled gems the payload provides
    # itself (used to decide whether a host native-extension gem can be
    # dropped in favor of the payload's own copy).
    #
    # The binary is executed through /bin/sh: an APE bootstraps itself
    # via its shell-script header on kernels without APE binfmt support,
    # while on kernels that do support it, sh's ENOEXEC fallback is
    # simply never needed. This also validates that the payload actually
    # runs on the build host. GEM_HOME/GEM_PATH are cleared so the query
    # sees only the payload's embedded gems, not the build host's.
    def query_ruby(ruby)
      script = 'print RUBY_VERSION; print "\t"; print Gem.default_dir; ' \
               'print "\t"; print Gem::Specification.map(&:name).uniq.sort.join(",")'
      out = IO.popen([{ "GEM_HOME" => nil, "GEM_PATH" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil },
                      "/bin/sh", ruby, "-e", script],
                     err: IO::NULL, &:read)
      ok = $?.success?
      version, default_gem_dir, gem_names = out.to_s.split("\t", 3)
      unless ok && version =~ /\A\d+\.\d+/ && default_gem_dir && !default_gem_dir.empty?
        raise "Failed to run the cosmopolitan Ruby #{ruby} on this host (exit status #{$?.exitstatus.inspect}, output #{out.inspect}); cannot package it with --cosmo-ruby"
      end
      { version: version,
        default_gem_dir: default_gem_dir,
        gem_names: gem_names.to_s.split(",") }
    end

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

    # The cosmocc toolchain to compile the APE launcher stub with. An
    # explicitly given --cosmo path always wins; otherwise the build host
    # is searched (see find_cc), which is what makes --cosmo-ruby alone
    # sufficient to package a portable application. Raises an actionable
    # error when no toolchain can be found.
    def require_cc(explicit = nil, env = ENV)
      return resolve_cc(explicit) unless explicit.nil? || explicit.to_s.empty?

      find_cc(env) ||
        raise("no cosmocc toolchain found, but one is needed to build the APE launcher stub: " \
              "#{COSMOCC_ENV} is not set, cosmocc is not in PATH, and none of the conventional " \
              "install locations (#{CONVENTIONAL_CC_PATHS.join(", ")}) has one. " \
              "Install the toolchain from https://cosmo.zip/pub/cosmocc/cosmocc.zip (unzip it, " \
              "then either add its bin directory to PATH or set #{COSMOCC_ENV} to it), " \
              "or name it explicitly with --cosmo <path-to-cosmocc>")
    end

    # Searches the build host for a cosmocc toolchain, in order: the
    # COSMOCC environment variable (the cosmocc executable or its
    # installation directory), cosmocc in PATH, and finally the
    # conventional install locations (CONVENTIONAL_CC_PATHS). Returns the
    # absolute path to cosmocc, or nil when nothing is found.
    #
    # COSMOCC is authoritative: if it is set but does not point at a
    # usable toolchain, that error is raised rather than silently using a
    # different toolchain than the user configured.
    def find_cc(env = ENV)
      specified = env[COSMOCC_ENV]
      unless specified.nil? || specified.empty?
        begin
          return resolve_cc(specified)
        rescue RuntimeError => e
          raise "#{COSMOCC_ENV}=#{specified} does not name a usable cosmocc toolchain: #{e.message}"
        end
      end

      search_path(env["PATH"]) || conventional_cc(env)
    end

    # The first executable cosmocc in the given PATH string, or nil.
    def search_path(path)
      return nil if path.nil? || path.empty?

      path.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        cc = File.expand_path(File.join(dir, "cosmocc"))
        return cc if File.file?(cc) && File.executable?(cc)
      end
      nil
    end

    # cosmocc in one of the conventional install locations, or nil. Within
    # a location holding several versioned toolchains (e.g.
    # ~/.cosmocc/3.9.2, ~/.cosmocc/4.0.2) the newest version wins.
    def conventional_cc(env = ENV)
      home = env["HOME"]

      CONVENTIONAL_CC_PATHS.each do |pattern|
        if pattern.start_with?("~/")
          next if home.nil? || home.empty?

          pattern = File.join(home, pattern.delete_prefix("~/"))
        end

        candidates = Dir.glob(pattern).select { |cc| File.file?(cc) && File.executable?(cc) }
        next if candidates.empty?

        return File.expand_path(candidates.max_by { |cc| version_key(cc) })
      end
      nil
    end

    # Sort key that orders <root>/<version>/bin/cosmocc paths newest
    # first; unversioned or unparsable directory names sort oldest.
    def version_key(cc)
      name = File.basename(File.dirname(File.dirname(cc)))
      Gem::Version.correct?(name) ? [1, Gem::Version.new(name)] : [0, Gem::Version.new("0")]
    end

    # Compiles the stub sources with the given cosmocc and returns the
    # path to the resulting APE stub binary. Results are cached in the
    # user cache directory, keyed on the toolchain and the stub sources,
    # so repeated packaging runs do not recompile. On compile failure the
    # compiler output is included in the raised error.
    def build_stub(cc)
      require "fileutils"
      require "tmpdir"

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
      require "digest"

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
      require "tmpdir"

      base = ENV["XDG_CACHE_HOME"]
      base = File.join(Dir.home, ".cache") if base.nil? || base.empty?
      File.join(base, "ocran")
    rescue ArgumentError # Dir.home unavailable (no HOME)
      File.join(Dir.tmpdir, "ocran-cache")
    end
  end
end
