# frozen_string_literal: true
require "tempfile"
require_relative "windows_command_escaping"

module Ocran
  class LauncherBatchBuilder
    include WindowsCommandEscaping

    # BATCH_FILE_DIR is a parameter expansion used in Windows batch files,
    # representing the full path to the directory where the batch file resides.
    # It allows for the use of pseudo-relative paths by referencing the
    # batch file's own location without changing the working directory.
    BATCH_FILE_DIR = "%~dp0"

    # BATCH_FILE_PATH is a parameter expansion used in Windows batch files,
    # representing the full path to the batch file itself, including the file name.
    BATCH_FILE_PATH = "%~f0"

    def initialize(chdir_before: nil, title: nil)
      @title = title
      @chdir_before = chdir_before
      @environments = {}
    end

    def build
      @file = Tempfile.open do |f|
        f.puts "@echo off"
        @environments.each { |name, val| f.puts build_set_command(name, val) }
        f.puts build_set_command("OCRAN_EXECUTABLE", BATCH_FILE_PATH)
        f.puts build_start_command(@title, @executable, @script, *@args, chdir_before: @chdir_before)
        f
      end
    end

    def export(name, value)
      @environments[name] = value
    end

    def exec(executable, script, *args)
      @executable, @script, @args = executable, script, args
    end

    def to_path
      @file.to_path
    end

    def replace_inst_dir_placeholder(s)
      s.to_s.gsub(/#{Regexp.escape(EXTRACT_ROOT.to_s)}[\/\\]/, BATCH_FILE_DIR)
    end
    private :replace_inst_dir_placeholder

    def build_set_command(name, value)
      "set \"#{name}=#{replace_inst_dir_placeholder(value)}\""
    end
    private :build_set_command

    def build_start_command(title, executable, script, *args, chdir_before: nil)
      cmd = ["start"]

      # Title for Command Prompt window title bar
      cmd << quote_and_escape(title)

      # Use /d to set the startup directory for the process,
      # which will be BATCH_FILE_DIR/SRCDIR. This path is where
      # the script is located, establishing the working directory
      # at process start.
      if chdir_before
        cmd << "/d #{quote_and_escape("#{BATCH_FILE_DIR}#{SRCDIR}")}"
      end

      cmd << quote_and_escape("#{BATCH_FILE_DIR}#{executable}")
      cmd << quote_and_escape("#{BATCH_FILE_DIR}#{script}")
      cmd += args.map { |arg| quote_and_escape(replace_inst_dir_placeholder(arg)) }

      # Forward batch file arguments to the command with `%*`
      cmd << "%*"

      cmd.join(" ")
    end
    private :build_start_command
  end
end
