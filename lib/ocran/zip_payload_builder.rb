# frozen_string_literal: true
require "pathname"
require "fileutils"
require_relative "build_constants"
require_relative "zip_writer"

module Ocran
  # Builder that packages an application by INJECTING it into the ZIP store
  # of a cosmopolitan Ruby APE, instead of building a launcher stub that
  # unpacks a temporary directory at every start.
  #
  # A CosmoRuby build auto-runs the member /zip/main.rb of its own archive
  # when there is one, passing the command line through as ARGV. So a
  # complete application is: a byte-for-byte copy of ruby.com, plus the
  # application's files, plus a generated main.rb that prepares the
  # environment and loads the real script. Nothing is compiled at packaging
  # time (no cosmocc) and nothing is written to disk at run time (no
  # extraction, no temp directory).
  #
  # Layout inside the archive:
  #
  #   /zip/main.rb                generated bootstrap, the entry point
  #   /zip/ocran/src/...          the application's own files
  #   /zip/ocran/gems/...         packed pure-Ruby gems (GEM_HOME/GEM_PATH)
  #   /zip/ocran/lib/ruby/...     files packed relative to the Ruby prefix
  #
  # Everything except main.rb lives under the "ocran/" prefix because the
  # interpreter's own standard library already occupies /zip/lib/ruby and
  # /zip/bin: a shared namespace would let a packed file shadow part of the
  # interpreter. The prefix makes collisions structurally impossible, and
  # it is the same tree the extraction mode would have written to a temp
  # directory, so Direction needs no separate layout.
  class ZipPayloadBuilder
    include BuildConstants

    # Where the interpreter maps its embedded archive.
    ZIP_ROOT = "/zip"
    # Root of the packed application inside the archive.
    APP_ROOT = "#{ZIP_ROOT}/ocran"
    # Archive member the interpreter runs on startup.
    MAIN_SCRIPT = "main.rb"

    # Uncompressed size of everything packed, for the build summary.
    attr_reader :data_size

    def initialize(path, cosmo_ruby:, chdir_before: false, debug_mode: false)
      @path = Pathname(path)
      @cosmo_ruby = Pathname(cosmo_ruby)
      @chdir_before = chdir_before
      @debug_mode = debug_mode
      @entries = []
      @names = {}
      @env = {}
      @exec_args = nil
      @ignored_symlinks = []
      @data_size = 0

      yield(self) if block_given?

      finalize
    end

    # Symlinks the extraction mode would create (libruby aliases). A ZIP
    # member cannot be a symlink zipos would follow, and none are needed:
    # the packed interpreter is a single static binary.
    attr_reader :ignored_symlinks

    def mkdir(target)
      add(Entry.new(name: "#{archive_name(target)}/"))
    end

    def cp(source, target)
      source = source.to_s
      add(Entry.new(name: archive_name(target), source: source, mode: file_mode(source),
                    mtime: File.mtime(source)))
      @data_size += File.size(source)
    end

    def symlink(link_path, target)
      @ignored_symlinks << [link_path.to_s, target.to_s]
    end

    def export(name, value)
      @env[name.to_s] = replace_root(value.to_s)
    end

    # The image argument is the packed interpreter the extraction mode
    # would spawn; here the running interpreter IS that binary, so only the
    # script and its arguments matter.
    def exec(image, script, *argv)
      raise "Script is already set" if @exec_args
      @exec_args = [in_archive(image), in_archive(script), argv.map { |arg| replace_root(arg.to_s) }]
    end

    private

    Entry = ZipWriter::Entry

    def add(entry)
      return if @names[entry.name]

      @names[entry.name] = true
      @entries << entry
    end

    # Archive member name for a target path of the extraction layout. The
    # targets Direction emits are relative to the extraction root, so they
    # only need the application prefix; an absolute target would escape the
    # archive and is a bug.
    def archive_name(target)
      name = target.to_s.tr("\\", "/").delete_prefix("./")
      raise "cannot pack the absolute path #{name} into a ZIP archive" if name.start_with?("/")

      "ocran/#{name}".chomp("/")
    end

    # Rewrites the extraction-root placeholder ("|", see BuildConstants)
    # that Direction puts into environment values and exec arguments: in
    # this mode the application root is not a temporary directory but a
    # fixed path inside the archive.
    def replace_root(value)
      value.gsub("#{EXTRACT_ROOT}/", "#{APP_ROOT}/").gsub(/\A#{Regexp.escape(EXTRACT_ROOT.to_s)}\z/, APP_ROOT)
    end

    # Absolute path inside the archive for a path Direction emits relative
    # to the extraction root.
    def in_archive(path)
      path = replace_root(path.to_s).tr("\\", "/")
      path.start_with?("/") ? path : "#{APP_ROOT}/#{path}"
    end

    # Executable bits are the only permission worth carrying over; packed
    # files are read-only inside the archive anyway.
    def file_mode(source)
      File.executable?(source) ? 0o755 : 0o644
    end

    def finalize
      raise "No script to run was recorded" unless @exec_args

      FileUtils.cp(@cosmo_ruby.to_s, @path.to_s)
      File.chmod(0o755, @path.to_s)

      add(Entry.new(name: MAIN_SCRIPT, data: bootstrap_source, mode: 0o644))
      ZipWriter.append(@path.to_s, @entries)
    end

    # The generated /zip/main.rb. It has to do what the C stub does after
    # extracting: set up the environment, then run the script.
    #
    # Environment variables cannot simply be exported here, because the
    # interpreter is already running by the time main.rb executes and has
    # long since read RUBYLIB, RUBYOPT and GEM_PATH. So each is applied by
    # its runtime equivalent: RUBYLIB by unshifting onto $LOAD_PATH,
    # GEM_HOME/GEM_PATH by setting them and telling RubyGems to re-read
    # them, RUBYOPT's -I/-r by acting on them directly. The variables are
    # also exported so that child processes see the same configuration.
    def bootstrap_source
      script = @exec_args[1]
      build_argv = @exec_args[2]

      sections = [
        <<~RUBY.chomp,
          # Generated by OCRAN. Entry point of the packaged application: the
          # cosmopolitan Ruby interpreter this file is embedded in runs it on
          # startup, with the command line in ARGV.
        RUBY
        (%{$stderr.puts "OCRAN: main.rb starting, ARGV=\#{ARGV.inspect}"} if @debug_mode),
        <<~RUBY.chomp,
          # Full path of the running executable. The interpreter resolves its
          # own image path, which for a packaged application IS the executable
          # the user started - the same meaning OCRAN_EXECUTABLE has in the
          # extraction mode.
          executable = RbConfig.ruby
          ENV["OCRAN_EXECUTABLE"] = executable
        RUBY
        chdir_source,
        env_source,
        load_path_source,
        gem_path_source,
        rubyopt_source,
        (<<~RUBY.chomp unless build_argv.empty?),
          # Arguments recorded at packaging time ("ocran app.rb -- a b") come
          # before the ones the user passes at run time.
          ARGV.unshift(#{build_argv.map(&:inspect).join(", ")})
        RUBY
        <<~RUBY.chomp,
          # Kernel#load, not require: the script must run with $0 and __FILE__
          # set to itself, so that "if __FILE__ == $0" guards fire and files
          # packed next to it are found through __dir__.
          $PROGRAM_NAME = #{script.inspect}
          load #{script.inspect}
        RUBY
      ]

      sections.compact.reject(&:empty?).join("\n\n") + "\n"
    end

    # --chdir-first cannot mean "change into the application directory"
    # here: the application lives inside the archive and zipos cannot be a
    # working directory. The directory holding the executable is the
    # closest equivalent, and the one an application that keeps data next
    # to itself actually wants.
    def chdir_source
      return "" unless @chdir_before

      <<~RUBY.chomp
        # --chdir-first: the archive cannot be a working directory, so use
        # the directory the executable was started from.
        Dir.chdir(File.dirname(executable))
      RUBY
    end

    # Environment variables other than the load-path ones, exported as is.
    def env_source
      plain = @env.reject { |name, _| %w[RUBYLIB RUBYOPT GEM_HOME GEM_PATH].include?(name) }
      return "" if plain.empty?

      plain.map { |name, value| "ENV[#{name.inspect}] = #{value.inspect}" }.join("\n")
    end

    def load_path_source
      paths = split_paths(@env["RUBYLIB"])
      return "" if paths.empty?

      <<~RUBY.chomp
        # RUBYLIB equivalent: the interpreter read the variable before this
        # file ran, so the entries are put on the load path directly. They
        # are also exported for child processes.
        ENV["RUBYLIB"] = #{@env["RUBYLIB"].inspect}
        $LOAD_PATH.unshift(*#{paths.inspect})
      RUBY
    end

    def gem_path_source
      home, path = @env["GEM_HOME"], @env["GEM_PATH"]
      return "" unless home || path

      <<~RUBY.chomp
        # RubyGems has already computed its paths from the environment it
        # started with; point it at the packed gems and make it re-read them.
        ENV["GEM_HOME"] = #{home.inspect}
        ENV["GEM_PATH"] = #{path.inspect}
        Gem.clear_paths
      RUBY
    end

    # RUBYOPT is likewise too late to export. -I and -r are replayed; every
    # other flag is reported at build time (see Direction) and dropped.
    def rubyopt_source
      rubyopt = @env["RUBYOPT"].to_s
      return "" if rubyopt.strip.empty?

      includes, requires = self.class.parse_rubyopt(rubyopt)
      lines = ["ENV[\"RUBYOPT\"] = #{rubyopt.inspect}"]
      lines << "$LOAD_PATH.unshift(*#{includes.inspect})" unless includes.empty?
      requires.each { |lib| lines << "require #{lib.inspect}" }
      lines.join("\n")
    end

    def split_paths(value)
      value.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
    end

    # Splits a RUBYOPT string into the -I directories and -r libraries that
    # can be replayed from inside the script, and the flags that cannot.
    # Returns [includes, requires, unsupported].
    def self.parse_rubyopt(rubyopt)
      includes, requires, unsupported = [], [], []

      rubyopt.split(/\s+/).reject(&:empty?).each do |token|
        case token
        when /\A-I(.+)\z/ then includes << $1
        when /\A-r(.+)\z/ then requires << $1
        else unsupported << token
        end
      end

      [includes, requires, unsupported]
    end
  end
end
