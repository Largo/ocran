# frozen_string_literal: true
require "open3"
require "pathname"
require_relative "command_output" unless defined?(Ocran::CommandOutput)
require_relative "aot_toolchain"
require_relative "spinel_compatibility"

module Ocran
  # Builds --spinel output: the script compiled ahead of time by Spinel
  # (https://github.com/matz/spinel) into a native executable, instead of
  # being packaged together with a Ruby interpreter.
  #
  # Spinel compiles a subset of Ruby, so whether this works depends on the
  # program. When it does, the result is one small binary that needs
  # nothing but libc. When it does not - or when Spinel is not installed -
  # the user gets a report of what in their code and in which gems stands
  # in the way, from SpinelCompatibility.
  class SpinelBuilder
    include CommandOutput

    # How much of the compiler's output is shown when it fails. The tail is
    # what names the error; a C compiler failure can run to thousands of
    # lines before it.
    MAX_OUTPUT_LINES = 60

    def initialize(option)
      @option = option
      @script = option.script
      @output = option.output_executable
    end

    # Keeps spin out of whatever bundle OCRAN was started under: a package's
    # native build step may shell out to Ruby.
    BUNDLER_FREE_ENV = {
      "RUBYOPT" => nil,
      "BUNDLER_SETUP" => nil,
      "BUNDLE_GEMFILE" => nil,
      "BUNDLE_LOCKFILE" => nil
    }.freeze

    def build
      spinel = AotToolchain.find(:spinel)
      spin_root = find_spin_root(@script.dirname)
      spin_flags = spin_root && spinel ? spin_flags(spin_root, spinel) : []
      analysis = SpinelCompatibility.new(@script, packages_dir: packages_dir(spinel),
                                                  package_roots: package_roots(spin_flags, spin_root),
                                                  project_dirs: project_dirs + [spin_root].compact,
                                                  # spin passes the project root as -I, so the
                                                  # program's requires resolve against it too
                                                  search_roots: [spin_root].compact).analyze

      unless spinel
        error "--spinel needs the Spinel compiler, which was not found."
        STDERR.puts
        STDERR.puts AotToolchain.install_instructions([:spinel])
        STDERR.puts
        print_report(analysis, "Meanwhile, a static check of whether #{display(@script)} is likely to compile with Spinel:")
        raise "Spinel is not installed"
      end

      verbose "Using Spinel at #{spinel} (#{AotToolchain.version(spinel) || "version unknown"})" if @option.verbose?
      warn_about_uncompiled_files(analysis)

      flags = spin_flags.dup
      given = include_roots(spin_flags)
      analysis.include_dirs.each { |dir| flags.push("-I", dir) unless given.include?(dir) }
      flags << "-g" if @option.enable_debug_mode?
      flags.concat(@option.spinel_options)
      command = [spinel, *flags, @script.to_s, "-o", @output.to_s]

      say "Compiling #{display(@script)} with Spinel"
      verbose command.join(" ")
      output, status = Open3.capture2e(*command)

      if status.success?
        STDERR.print output if !output.strip.empty? && @option.warning?
        report_success(analysis)
      else
        report_failure(spinel, flags, output, status, analysis)
      end
    end

    private

    def report_success(analysis)
      unless analysis.findings.empty?
        warning "Spinel compiled the program, but the static check flagged #{analysis.findings.size} " \
                "construct(s) that may behave differently than under CRuby#{@option.verbose? ? ":" : " (--verbose lists them)"}"
        verbose analysis.report
      end
      say "Finished building #{@output} (#{File.size(@output)} bytes)"
      say "This is a native executable for this platform; it does not need Ruby to run."
    end

    def report_failure(spinel, flags, output, status, analysis)
      lines = output.lines
      STDERR.puts "Spinel could not compile #{display(@script)} (exit status #{status.exitstatus.inspect}):"
      STDERR.puts "  ... (#{lines.size - MAX_OUTPUT_LINES} earlier lines omitted)" if lines.size > MAX_OUTPUT_LINES
      STDERR.puts lines.last(MAX_OUTPUT_LINES).map { |l| "  #{l}" }.join
      STDERR.puts

      if analysis.clean?
        STDERR.puts "The static check found nothing Spinel is known to reject in #{analysis.files.size} file(s),"
        STDERR.puts "so the cause is likely a limit of Spinel's type inference rather than a missing feature."
      else
        print_report(analysis, "What may stand in the way:")
      end
      print_doctor(spinel, flags)

      STDERR.puts
      STDERR.puts "Things to try:"
      STDERR.puts "  - Spinel's supported subset: #{AotToolchain::SPINEL_URL}/blob/master/docs/limitations.md"
      STDERR.puts "  - --spinel-opt --defer-refusals builds anyway; refused methods then raise NotImplementedError when called"
      STDERR.puts "  - --spinel-opt --warn-widen shows where inference gave up on a type"
      unless analysis.problem_gems.empty?
        names = analysis.problem_gems.map(&:name).join(", ")
        STDERR.puts "  - replace or drop the gems Spinel cannot compile (#{names}), or leave out --spinel to package them with Ruby"
        if analysis.problem_gems.any?(&:native)
          STDERR.puts "  - Spinel compiles native code only from spin packages: with a spin.toml beside the script"
          STDERR.puts "    (`spin init`) whose dependencies provide those libraries, OCRAN builds with `spin flags`"
          STDERR.puts "    (#{AotToolchain::SPINEL_URL}/blob/master/docs/spin.md)"
        end
      end
      raise "Spinel could not compile #{display(@script)}"
    end

    # spinel-doctor, installed beside the compiler, adds what the compile
    # error alone does not say: calls that degrade to nil, methods whose
    # types inference gave up on, requires it treats as no-ops. Its build
    # leg repeats the compiler output shown already, and its behavior leg
    # runs the program under CRuby, so both are left out.
    def print_doctor(spinel, flags)
      doctor = doctor_path(spinel) or return

      verbose "Running #{doctor}"
      env = { "SPINEL" => spinel }
      command = [doctor, "--skip", "build,behavior", @script.to_s]
      command.concat(["--", *flags]) unless flags.empty?
      output, = Open3.capture2e(env, *command)
      return if output.strip.empty?

      STDERR.puts
      STDERR.puts "spinel-doctor's report:"
      STDERR.puts output.lines.last(MAX_OUTPUT_LINES).map { |l| "  #{l}" }.join
    rescue SystemCallError => e
      verbose "spinel-doctor could not be run: #{e.message}"
    end

    # `make install` puts it in PREFIX/bin, beside the link to the compiler
    # in PREFIX/lib/spinel; a source checkout has both in bin/.
    def doctor_path(spinel)
      candidates = [File.dirname(spinel)]
      real = File.realpath(spinel)
      candidates += [File.dirname(real), File.join(File.dirname(File.dirname(real)), "bin"),
                     File.join(File.dirname(File.dirname(File.dirname(real))), "bin")]
      candidates.uniq.map { |dir| File.join(dir, "spinel-doctor") }.find { |path| AotToolchain.executable?(path) }
    rescue SystemCallError
      nil
    end

    def print_report(analysis, heading)
      STDERR.puts heading
      STDERR.puts
      STDERR.puts analysis.report.gsub(/^(?=.)/, "  ")
    end

    # The directory of the spin project the script is in: the nearest one
    # up from it with a spin.toml, as spin itself finds it. Unlike spin, the
    # search stops at the repository root (.git) and the home directory and
    # never takes /, so a stray spin.toml far above the program does not
    # turn every build under it into a spin build.
    def find_spin_root(dir)
      dir = File.expand_path(dir)
      home = (File.expand_path("~") rescue nil)
      loop do
        up = File.dirname(dir)
        return nil if up == dir

        return dir if File.file?(File.join(dir, "spin.toml"))
        return nil if dir == home || File.exist?(File.join(dir, ".git"))

        dir = up
      end
    end

    # The flags `spin flags` prints for the project: the -I roots of its
    # dependencies, the objects of the C they carry (--link) and
    # --strict-require. Running it also resolves the dependencies and
    # compiles their C, which is what makes the --link paths real.
    def spin_flags(root, spinel)
      spin = AotToolchain.find(:spin)
      unless spin
        error "#{display(root)} is a spin project (spin.toml), which needs the spin command to resolve " \
              "its dependencies, and it was not found."
        STDERR.puts
        STDERR.puts AotToolchain.install_instructions([:spin])
        raise "spin is not installed"
      end

      say "Resolving the dependencies of the spin project in #{display(root)}"
      # spin runs spinel by name, so the one OCRAN found goes first on PATH.
      path = [File.dirname(spinel), File.dirname(spin), ENV.fetch("PATH", "")].uniq.join(File::PATH_SEPARATOR)
      env = BUNDLER_FREE_ENV.merge("PATH" => path)
      verbose "#{spin} flags (in #{root})"
      out, err, status = Open3.capture3(env, spin, "flags", chdir: root)
      unless status.success?
        STDERR.puts "spin could not resolve the project's dependencies (exit status #{status.exitstatus.inspect}):"
        STDERR.puts (err + out).lines.last(MAX_OUTPUT_LINES).map { |l| "  #{l}" }.join
        if (err + out).include?("--allow-native-build")
          STDERR.puts
          STDERR.puts "Set SPIN_ALLOW_NATIVE_BUILD=1 for this build, or run `spin trust <package>` once, to let"
          STDERR.puts "spin run the native build steps of the dependencies."
        end
        raise "spin flags failed in #{display(root)}"
      end
      check_spin_flags(out.split, root)
    rescue SystemCallError => e
      raise "spin could not be run: #{e.message}"
    end

    # spin joins its flags with spaces and does not quote them, so a path
    # with a space in it arrives in pieces. Every path a flag names has to
    # exist; rejoining pieces would only be a guess.
    PATH_FLAGS = { "-I" => :directory?, "--rbs" => :directory?, "--link" => :exist? }.freeze

    def check_spin_flags(flags, root)
      flags.each_cons(2) do |flag, value|
        test = PATH_FLAGS[flag] or next
        next if flag == "--link" && value.start_with?("-") # --link -ljemalloc

        next if File.public_send(test, value)

        raise "`spin flags` in #{display(root)} names #{value.inspect} (#{flag}), which does not exist. " \
              "spin prints its flags unquoted, so a project or dependency whose path contains a space " \
              "cannot be passed on; move it to a path without spaces"
      end
      flags
    end

    def include_roots(flags)
      flags.each_cons(2).select { |flag, _| flag == "-I" }.map { |_, dir| dir }
    end

    # The dependencies' roots: every -I root but the project's own, whose
    # files the scan reads as the program's.
    def package_roots(flags, spin_root)
      include_roots(flags).reject { |dir| spin_root && File.expand_path(dir) == spin_root }
    end

    # Files given on the command line besides the script, which Spinel
    # compiles in only when the program requires them. Anything else -
    # data files, assets - is not part of the binary.
    def warn_about_uncompiled_files(analysis)
      compiled = analysis.files.map(&:to_s)
      extra = @option.source_files.drop(1).reject { |f| compiled.include?(f.to_s) }
      return if extra.empty?

      shown = extra.first(5).map { |f| display(f) }.join(", ")
      shown += ", ..." if extra.size > 5
      warning "Spinel compiles code only; #{extra.size} file(s) given on the command line are not " \
              "part of the executable and have to be shipped beside it: #{shown}"
    end

    # Directories whose files are the program's own rather than a gem's.
    def project_dirs
      [@script.dirname, *@option.source_files.map(&:dirname)].uniq
    end

    # Spinel's packages/ directory, which lists the standard library it
    # provides: beside the compiler when installed, at the root of a source
    # checkout otherwise (where `spinel` links to build/spinel).
    def packages_dir(spinel)
      return nil unless spinel

      real = File.realpath(spinel)
      [File.dirname(real), File.dirname(File.dirname(real))]
        .map { |dir| File.join(dir, "packages") }
        .find { |dir| File.directory?(dir) }
    rescue SystemCallError
      nil
    end

    # Relative to the working directory when inside it, else absolute.
    def display(path)
      rel = Pathname(path).relative_path_from(Pathname.pwd).to_s
      rel.start_with?("..") ? path.to_s : rel
    rescue ArgumentError
      path.to_s
    end
  end
end
