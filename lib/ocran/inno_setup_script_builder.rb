# frozen_string_literal: true
require "tempfile"
require_relative "file_path_set"
require_relative "windows_command_escaping"

module Ocran
  class InnoSetupScriptBuilder
    ISCC_CMD = "ISCC"
    ISCC_SUCCESS = 0
    ISCC_INVALID_PARAMS = 1
    ISCC_COMPILATION_FAILED = 2

    class << self
      # Whether the ISCC command can be run. On Windows it is invoked
      # directly and a missing ISCC is reported by compile; on POSIX it is
      # looked up in PATH (e.g. a Wine wrapper, or a fake ISCC in tests).
      def iscc_available?
        return true if Gem.win_platform?

        system("command -v #{ISCC_CMD} > /dev/null 2>&1")
      end

      def compile(iss_filename, quiet: false)
        unless iscc_available?
          raise "ISCC command not found. Is the InnoSetup directory in your PATH?"
        end

        cmd_line = [ISCC_CMD]
        cmd_line << "/Q" if quiet
        cmd_line << iss_filename
        system(*cmd_line)

        case $?&.exitstatus
        when ISCC_SUCCESS
          # ISCC reported success
        when ISCC_INVALID_PARAMS
          raise "ISCC reports invalid command line parameters"
        when ISCC_COMPILATION_FAILED
          raise "ISCC reports that compilation failed"
        else
          raise "ISCC failed to run"
        end
      end
    end

    include WindowsCommandEscaping

    def initialize(inno_setup_script)
      # ISSC generates the installer files relative to the directory of the
      # ISS file. Therefore, it is necessary to create Tempfiles in the
      # working directory.
      @build_file = Tempfile.new("", Dir.pwd)
      if inno_setup_script
        IO.copy_stream(inno_setup_script, @build_file)
      end
      @dirs = FilePathSet.new
      @files = FilePathSet.new
    end

    def build
      @build_file.tap do |f|
        if @dirs.any?
          f.puts
          f.puts "[Dirs]"
          @dirs.each { |_source, target| f.puts build_dir_item(target) }
        end

        if @files.any?
          f.puts
          f.puts "[Files]"
          @files.each { |source, target| f.puts build_file_item(source, target) }
        end
      end.close
      path
    end

    def path
      @build_file.to_path
    end

    def compile(verbose: false)
      InnoSetupScriptBuilder.compile(path, quiet: !verbose)
    end

    def mkdir(target)
      @dirs.add?("/", target)
    end

    # Symbolic links cannot be expressed in an Inno Setup script. They only
    # occur when building from POSIX hosts (e.g. libruby.so links); Windows
    # installations do not need them, so they are skipped.
    def symlink(_target, _link_name)
      nil
    end

    def cp(source, target)
      unless File.exist?(source)
        raise "The file does not exist (#{source})"
      end

      @files.add?(source, target)
    end

    # Inno Setup expands "{...}" as a constant (e.g. {app}) in the Name,
    # DestDir and DestName parameters, and "{{" is how a literal brace is
    # written there. Source is read by the compiler, which expands no
    # constants in it (short of the external flag), so it stays as it is.
    def escape_braces(s)
      s.to_s.gsub("{", "{{")
    end
    private :escape_braces

    def build_dir_item(target)
      name = File.join("{app}", escape_braces(target))
      "Name: #{quote_and_escape(name)};"
    end
    private :build_dir_item

    def build_file_item(source, target)
      dest_dir = File.join("{app}", escape_braces(File.dirname(target)))
      s = [
        "Source: #{quote_and_escape(source)};",
        "DestDir: #{quote_and_escape(dest_dir)};"
      ]
      src_name = File.basename(source)
      dest_name = File.basename(target)
      # A name taken over from Source would be expanded unescaped.
      if src_name != dest_name || dest_name.include?("{")
        s << "DestName: #{quote_and_escape(escape_braces(dest_name))};"
      end
      s.join(" ")
    end
    private :build_file_item
  end
end
