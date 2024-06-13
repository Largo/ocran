# frozen_string_literal: true
require "tempfile"
require_relative "windows_command_escaping"

module Ocran
  class InnoSetupScriptBuilder
    include WindowsCommandEscaping

    attr_reader :files

    def initialize(inno_setup_script)
      @inno_setup_script = inno_setup_script
      @dirs = {}
      @files = {}
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
      return if target.to_s == "."

      key = target.to_s.downcase
      return if @dirs[key]
      @dirs[key] = target

      @_dirs << { name: File.join("{app}", target) }
    end

    def copy_file(source, target)
      unless File.exist?(source)
        raise "The file does not exist (#{source})"
      end

      key = target.to_s.downcase
      return if @files[key]
      @files[key] = [target, source]

      @_files << {
        source: source,
        dest_dir: File.join("{app}", File.dirname(target)),
        dest_name: File.basename(target)
      }
    end

    alias copy copy_file
    alias cp copy_file

    def touch(target)
      @empty_source ||= Tempfile.new.tap { |f| f.close }
      copy_file(@empty_source.to_path, target)
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
