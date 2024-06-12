# frozen_string_literal: true
require "tempfile"
require_relative "windows_command_escaping"

module Ocran
  class InnoSetupScriptBuilder
    include WindowsCommandEscaping

    def initialize(inno_setup_script, files: [], dirs: [])
      @inno_setup_script = inno_setup_script
      @files = files
      @dirs = dirs
    end

    def build
      @file = Tempfile.open do |f|
        IO.copy_stream(@inno_setup_script, f) if @inno_setup_script

        unless @dirs.empty?
          f.puts
          f.puts "[Dirs]"
          @dirs.each { |obj| f.puts build_dirs_section_item(**obj) }
        end
        unless @files.empty?
          f.puts
          f.puts "[Files]"
          @files.each { |obj| f.puts build_files_section_item(**obj) }
        end
        f
      end
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
