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
