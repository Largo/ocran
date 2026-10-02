# frozen_string_literal: true
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require_relative "command_output" unless defined?(Ocran::CommandOutput)
require_relative "aot_toolchain"

module Ocran
  # Builds --roundhouse output: a Rails application compiled to a native
  # server binary by Roundhouse (https://github.com/rubys/roundhouse) and
  # Spinel (https://github.com/matz/spinel).
  #
  # Roundhouse lowers the app to the subset of Ruby Spinel compiles and
  # writes it out as a spin project; `spin build` compiles that. The binary
  # reads its static assets, configuration and SQLite database from beside
  # it, so the result is a directory: the binary plus those files.
  #
  # Whether an app gets through depends on how much of it Roundhouse covers
  # yet. When it does not - or when the tools are missing - the user gets
  # Roundhouse's own analysis of the app (`roundhouse check`), whose gem
  # census says which of the app's gems it does not model.
  class RoundhouseBuilder
    include CommandOutput

    # What the binary reads at run time, copied from the generated project.
    RUNTIME_DIRS = %w[static public db config].freeze

    MAX_OUTPUT_LINES = 60
    MAX_CHECK_ERRORS = 15

    # Keeps the child tools out of whatever bundle OCRAN was started under:
    # Roundhouse's spin project may shell out to Ruby (asset steps, tests).
    BUNDLER_FREE_ENV = {
      "RUBYOPT" => nil,
      "BUNDLER_SETUP" => nil,
      "BUNDLE_GEMFILE" => nil,
      "BUNDLE_LOCKFILE" => nil
    }.freeze

    def initialize(option)
      @option = option
      @app = option.roundhouse_app
      @output = option.roundhouse_output
    end

    def build
      tools = AotToolchain.find_all(%i[roundhouse spinel spin])
      missing = tools.select { |_, path| path.nil? }.keys
      report_missing_tools(tools, missing) unless missing.empty?

      tools.each do |name, path|
        verbose "Using #{name} at #{path} (#{AotToolchain.version(path) || "version unknown"})"
      end

      work = Dir.mktmpdir("ocran-roundhouse")
      project = File.join(work, "spinel")
      @env = child_env(tools)

      say "Transpiling #{display(@app)} with Roundhouse"
      command = [tools[:roundhouse], "--target", "spinel", *@option.roundhouse_options, "-o", project, @app.to_s]
      output, status = run(command)
      transpile_failed(tools, output, status, work) unless status.success?

      say "Compiling with Spinel (spin build); the first build of a large app can take a few minutes"
      output, status = run([tools[:spin], "build"], chdir: project)
      compile_failed(tools, output, status, work) unless status.success?

      install(project)
      FileUtils.remove_entry(work)
    end

    private

    def run(command, chdir: Dir.pwd)
      verbose command.join(" ")
      Open3.capture2e(@env, *command, chdir: chdir)
    rescue SystemCallError => e
      [e.message, nil]
    end

    # spin calls spinel by name, so a spinel found outside PATH (through
    # SPINEL or a conventional location) is put on the child's PATH.
    def child_env(tools)
      dirs = tools.values.compact.map { |path| File.dirname(path) }.uniq
      BUNDLER_FREE_ENV.merge("PATH" => (dirs + [ENV.fetch("PATH", "")]).join(File::PATH_SEPARATOR))
    end

    def report_missing_tools(tools, missing)
      commands = missing.map { |name| "`#{AotToolchain::TOOLS[name].command}`" }
      list = commands.size > 1 ? "#{commands[0..-2].join(", ")} and #{commands[-1]}" : commands.first
      error "--roundhouse needs #{list}, which #{missing.size == 1 ? "was" : "were"} not found."
      STDERR.puts
      STDERR.puts AotToolchain.install_instructions(missing)
      STDERR.puts

      if tools[:roundhouse]
        @env = child_env(tools)
        print_check(tools[:roundhouse], "Meanwhile, Roundhouse's analysis of #{display(@app)}:")
      else
        STDERR.puts "Once Roundhouse is installed, `roundhouse check --continue #{display(@app)}` lists the gems"
        STDERR.puts "and constructs of the app it does not cover yet; OCRAN shows it when a build fails."
      end
      raise "the Roundhouse toolchain is not installed"
    end

    def transpile_failed(tools, output, status, work)
      print_failure("Roundhouse could not transpile #{display(@app)}", output, status)
      print_check(tools[:roundhouse], "Roundhouse's analysis of the app:")
      STDERR.puts
      STDERR.puts "Things to try:"
      STDERR.puts "  - what Roundhouse covers: #{AotToolchain::ROUNDHOUSE_URL}/blob/main/docs/guide/rails-coverage.md"
      STDERR.puts "  - --roundhouse-opt --survey --roundhouse-opt --allow-unsupported transpiles an app that is"
      STDERR.puts "    not fully covered yet, with a stub at each unsupported site"
      STDERR.puts "  - the generated project so far is in #{work}"
      raise "Roundhouse could not transpile #{display(@app)}"
    end

    def compile_failed(tools, output, status, work)
      print_failure("Spinel could not compile the transpiled app (spin build)", output, status)

      STDERR.puts "Things to check:"
      versions = tools.map { |name, path| "#{name}: #{AotToolchain.version(path) || "version unknown"}" }
      STDERR.puts "  - versions in use (#{versions.join("; ")}); each Roundhouse snapshot names the Spinel"
      STDERR.puts "    release it was tested against in #{AotToolchain::ROUNDHOUSE_URL}/blob/main/RELEASES.md,"
      STDERR.puts "    and a mismatch is the most common cause of a failing build"
      missing_libs.each do |lib, package|
        STDERR.puts "  - the #{lib} development headers seem to be missing (#{package})"
      end
      STDERR.puts "  - the generated project is kept in #{File.join(work, "spinel")}; run `spin build` there to retry"
      STDERR.puts "  - a compiler error in the generated code is a bug in Roundhouse or Spinel: please report it"
      raise "Spinel could not compile the transpiled app"
    end

    def print_failure(heading, output, status)
      lines = output.to_s.lines
      exit_status = status ? "exit status #{status.exitstatus.inspect}" : "could not be started"
      STDERR.puts "#{heading} (#{exit_status}):"
      STDERR.puts "  ... (#{lines.size - MAX_OUTPUT_LINES} earlier lines omitted)" if lines.size > MAX_OUTPUT_LINES
      STDERR.puts lines.last(MAX_OUTPUT_LINES).map { |l| "  #{l}" }.join
      STDERR.puts
    end

    # Prints the useful part of `roundhouse check --continue`: the gem
    # census (which gems Roundhouse does not model), the summary, the first
    # errors and the punch list of unsupported constructs. The full report
    # of a large app runs to thousands of lines.
    def print_check(roundhouse, heading)
      say "Analyzing #{display(@app)} with roundhouse check"
      output, status = run([roundhouse, "check", "--continue", @app.to_s])
      return STDERR.puts("(roundhouse check could not be run: #{output.to_s.strip})") unless status

      lines = output.lines.map(&:chomp)
      summary = lines.grep(/\Aroundhouse-check:/)
      errors = lines.grep(/: error\[/)
      survey_start = lines.index { |l| l.include?("Survey:") }
      survey = survey_start ? lines[survey_start..].take_while { |l| !l.start_with?("roundhouse-check:") }.reject(&:empty?) : []

      STDERR.puts heading
      STDERR.puts
      summary.each { |l| STDERR.puts "  #{l}" }
      if summary.any? { |l| l.match?(/\d+ unknown/) && !l.match?(/\b0 unknown/) }
        STDERR.puts "  (\"unknown\" gems are ones Roundhouse does not model: code using them cannot be compiled yet)"
      end
      unless errors.empty?
        STDERR.puts
        errors.first(MAX_CHECK_ERRORS).each { |l| STDERR.puts "  #{l}" }
        STDERR.puts "  ... and #{errors.size - MAX_CHECK_ERRORS} more error(s)" if errors.size > MAX_CHECK_ERRORS
      end
      unless survey.empty?
        STDERR.puts
        survey.first(30).each { |l| STDERR.puts "  #{l}" }
      end
      STDERR.puts
      STDERR.puts "  Full report: roundhouse check --continue #{display(@app)}"
    end

    # Libraries the generated project links that pkg-config cannot find,
    # as [library, package hint] pairs. Empty when pkg-config is not there
    # to ask.
    def missing_libs
      return [] unless AotToolchain.search_path("pkg-config")

      { "sqlite3" => "libsqlite3-dev / brew install sqlite",
        "jemalloc" => "libjemalloc-dev / brew install jemalloc" }.reject do |lib, _|
        Kernel.system("pkg-config", "--exists", lib)
      end.to_a
    end

    def install(project)
      bin_dir = File.join(project, "build", "bin")
      binaries = Dir.glob(File.join(bin_dir, "*")).select { |f| File.file?(f) && File.executable?(f) }
      binary = binaries.find { |f| File.basename(f, ".*") == @app.basename.to_s } || binaries.first
      raise "spin build succeeded but produced no executable in #{bin_dir}" unless binary

      @output.mkpath
      target = @output + File.basename(binary)
      FileUtils.cp(binary, target)
      File.chmod(0o755, target)

      RUNTIME_DIRS.each do |dir|
        source = File.join(project, dir)
        next unless File.directory?(source)

        FileUtils.rm_rf(@output + dir)
        FileUtils.cp_r(source, @output + dir)
      end
      # storage/ holds the database and uploads, so a rebuild keeps it.
      (@output + "storage").mkpath

      seed_database
      say "Finished building #{display(@output)}"
      say "Run it with: cd #{display(@output)} && ./#{File.basename(binary)}  (serves on port 3000; PORT or -p to change)"
      say "It needs libsqlite3 and libjemalloc at run time (Debian/Ubuntu: libsqlite3-0 libjemalloc2)."
    end

    # Creates the database from the generated seed on the first build, when
    # the sqlite3 command is there to do it.
    def seed_database
      seed = @output + "db" + "seed.sql"
      database = @output + "storage" + "development.sqlite3"
      return unless seed.file? && !database.exist?

      sqlite3 = AotToolchain.search_path("sqlite3")
      unless sqlite3
        say "Create the database before the first start: sqlite3 storage/development.sqlite3 < db/seed.sql"
        return
      end

      verbose "Seeding #{database} from #{seed}"
      unless Kernel.system(sqlite3, database.to_s, in: seed.to_s)
        warning "Could not create the database from #{seed}; run: sqlite3 storage/development.sqlite3 < db/seed.sql"
      end
    end

    def display(path)
      Pathname(path).relative_path_from(Pathname.pwd).to_s
    rescue ArgumentError
      path.to_s
    end
  end
end
