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

    def build
      spinel = AotToolchain.find(:spinel)
      analysis = SpinelCompatibility.new(@script, packages_dir: packages_dir(spinel),
                                                  project_dirs: project_dirs).analyze

      unless spinel
        error "--spinel needs the Spinel compiler, which was not found."
        STDERR.puts
        STDERR.puts AotToolchain.install_instructions([:spinel])
        STDERR.puts
        print_report(analysis, "Meanwhile, a static check of whether #{display(@script)} is likely to compile with Spinel:")
        raise "Spinel is not installed"
      end

      verbose "Using Spinel at #{spinel} (#{AotToolchain.version(spinel) || "version unknown"})"
      warn_about_uncompiled_files(analysis)

      flags = analysis.include_dirs.flat_map { |dir| ["-I", dir] }
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

    def doctor_path(spinel)
      candidates = [File.dirname(spinel)]
      real = File.realpath(spinel)
      candidates += [File.dirname(real), File.join(File.dirname(File.dirname(real)), "bin")]
      candidates.uniq.map { |dir| File.join(dir, "spinel-doctor") }.find { |path| AotToolchain.executable?(path) }
    rescue SystemCallError
      nil
    end

    def print_report(analysis, heading)
      STDERR.puts heading
      STDERR.puts
      STDERR.puts analysis.report.gsub(/^(?=.)/, "  ")
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
