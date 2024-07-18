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
    end

    def build
      # ISSC generates the installer files relative to the directory of the
      # ISS file. Therefore, it is necessary to create Tempfiles in the
      # working directory.
      @file = Tempfile.open("", Dir.pwd) do |f|
        IO.copy_stream(@inno_setup_script, f) if @inno_setup_script

        if @dirs.any?
          f.puts
          f.puts "[Dirs]"
          @dirs.each do |_source, target|
            f.puts build_dirs_section_item(
                     name: File.join("{app}", target)
                   )
          end
        end
        if @files.any?
          f.puts
          f.puts "[Files]"
          @files.each do |source, target|
            f.puts build_files_section_item(
                     source: source,
                     dest_dir: File.join("{app}", File.dirname(target)),
                     dest_name: File.basename(target)
                   )
          end
        end
        f
      end
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
