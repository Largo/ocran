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

    extend WindowsCommandEscaping

    class << self
      def compile(iss_filename, quiet: false)
        unless system("where #{quote_and_escape(ISCC_CMD)} >NUL 2>&1")
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
      @inno_setup_script = inno_setup_script
      @dirs = FilePathSet.new
      @files = FilePathSet.new
    end

    def build
      # ISSC generates the installer files relative to the directory of the
      # ISS file. Therefore, it is necessary to create Tempfiles in the
      # working directory.
      @file = Tempfile.open("", Dir.pwd) do |f|
        if @inno_setup_script
          IO.copy_stream(@inno_setup_script, f)
        end

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

        f
      end
      @file.to_path
    end

    def compile(verbose: false)
      InnoSetupScriptBuilder.compile(@file.to_path, quiet: !verbose)
    end

    def mkdir(target)
      @dirs.add?("/", target)
    end

    def cp(source, target)
      unless File.exist?(source)
        raise "The file does not exist (#{source})"
      end

      @files.add?(source, target)
    end

    def to_path
      @file.to_path
    end

    def build_dir_item(target)
      name = File.join("{app}", target)
      "Name: #{quote_and_escape(name)};"
    end
    private :build_dir_item

    def build_file_item(source, target)
      dest_dir = File.join("{app}", File.dirname(target))
      s = [
        "Source: #{quote_and_escape(source)};",
        "DestDir: #{quote_and_escape(dest_dir)};"
      ]
      src_name = File.basename(source)
      dest_name = File.basename(target)
      if src_name != dest_name
        s << "DestName: #{quote_and_escape(dest_name)};"
      end
      s.join(" ")
    end
    private :build_file_item
  end
end
