# frozen_string_literal: true
require "tempfile"
require_relative "file_path_set"
require_relative "windows_command_escaping"

module Ocran
  class InnoSetupScriptBuilder
    include WindowsCommandEscaping

    def initialize(inno_setup_script)
      @inno_setup_script = inno_setup_script
      @dirs = FilePathSet.new
      @files = FilePathSet.new
      @_dirs = []
      @_files = []
    end

    def build
      # ISSC generates the installer files relative to the directory of the
      # ISS file. Therefore, it is necessary to create Tempfiles in the
      # working directory.
      @file = Tempfile.open("", Dir.pwd) do |f|
        IO.copy_stream(@inno_setup_script, f) if @inno_setup_script

        unless @_dirs.empty?
          f.puts
          f.puts "[Dirs]"
          @_dirs.each { |obj| f.puts build_dirs_section_item(**obj) }
        end
        unless @_files.empty?
          f.puts
          f.puts "[Files]"
          @_files.each { |obj| f.puts build_files_section_item(**obj) }
        end
        f
      end
    end

    def mkdir(target)
      return unless @dirs.add?("/", target)

      @_dirs << { name: File.join("{app}", target) }
    end

    def cp(source, target)
      unless File.exist?(source)
        raise "The file does not exist (#{source})"
      end

      return unless @files.add?(source, target)

      @_files << {
        source: source,
        dest_dir: File.join("{app}", File.dirname(target)),
        dest_name: File.basename(target)
      }
    end

    def to_path
      @file.to_path
    end

    def build_dirs_section_item(name:)
      "Name: #{quote_and_escape(name)};"
    end
    private :build_dirs_section_item

    def build_files_section_item(source:, dest_dir:, dest_name: nil)
      s = ["Source: #{quote_and_escape(source)};"]
      s << "DestDir: #{quote_and_escape(dest_dir)};"
      if dest_name
        s << "DestName: #{quote_and_escape(dest_name)};"
      end
      s.join(" ")
    end
    private :build_files_section_item
  end
end
