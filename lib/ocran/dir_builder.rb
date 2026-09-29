# frozen_string_literal: true
require "pathname"
require "fileutils"
require_relative "build_constants"
require_relative "windows_command_escaping"

module Ocran
  # Builder that outputs all files to a plain directory instead of a self-extracting
  # executable.  A launch script (`.sh` on POSIX, `.bat` on Windows) is written at
  # the root of the directory so the packaged app can be started directly.
  class DirBuilder
    include BuildConstants, WindowsCommandEscaping

    WINDOWS = Gem.win_platform?

    attr_reader :data_size
    # Recorded launch data (environment variables and exec arguments), used
    # by Direction to build the optional wrapper executable.
    attr_reader :env, :exec_args

    def initialize(path)
      @path = Pathname(path)
      @path.mkpath
      @env = {}
      @exec_args = nil
      @symlinks = []
      @data_size = 0

      yield(self) if block_given?

      finalize
    end

    def mkdir(target)
      (@path / target).mkpath
    end

    def cp(source, target)
      dest = @path / target
      dest.dirname.mkpath
      src = source.to_s
      FileUtils.cp(src, dest.to_s)
      @data_size += File.size(src)
    end

    def symlink(link_path, target)
      @symlinks << [link_path.to_s, target.to_s]
    end

    def export(name, value)
      @env[name.to_s] = value.to_s
    end

    def exec(image, script, *argv)
      raise "Script is already set" if @exec_args
      @exec_args = [image.to_s, script.to_s, argv.map(&:to_s)]
    end

    # Create a zip archive from a source directory.
    # Uses the `zip` command on POSIX and PowerShell on Windows.
    def self.create_zip(zip_path, source_dir)
      zip_path = File.expand_path(zip_path.to_s)
      if Gem.win_platform?
        system("powershell", "-NoProfile", "-Command",
               "Compress-Archive -Path '#{source_dir}\\*' -DestinationPath '#{zip_path}'",
               exception: true)
      else
        Dir.chdir(source_dir) do
          system("zip", "-r", zip_path, ".", exception: true)
        end
      end
    end

    private

    def finalize
      unless WINDOWS
        @symlinks.each do |link_path, target|
          dest = @path / link_path
          dest.dirname.mkpath
          File.symlink(target, dest) unless dest.exist?
        end
      end

      write_launch_script
    end

    # Anchors a relative packed path at the extraction root placeholder;
    # absolute paths are kept as they are.
    def root_path(path)
      return path if path.start_with?("#{EXTRACT_ROOT}/") || File.absolute_path?(path)
      "#{EXTRACT_ROOT}/#{path}"
    end

    # Quotes +value+ as one POSIX shell word. The extraction root placeholder
    # becomes "$SCRIPT_DIR"; everything else is single-quoted, so the shell
    # expands nothing in it.
    def shell_word(value)
      word = value.split("#{EXTRACT_ROOT}/", -1).map { |part|
        part.empty? ? "" : "'#{part.gsub("'", %q('"'"'))}'"
      }.join('"$SCRIPT_DIR"/')
      word.empty? ? "''" : word
    end

    # Renders +value+ for a double-quoted string in a batch file. Percent
    # signs are doubled so cmd.exe expands nothing in it, and the extraction
    # root placeholder becomes %SCRIPT_DIR%, which ends in a backslash.
    def batch_value(value)
      escape_percent(value).gsub("#{EXTRACT_ROOT}/", "%SCRIPT_DIR%")
    end

    def script_basename
      @exec_args ? Pathname(@exec_args[1]).basename.sub_ext("").to_s : "run"
    end

    def write_launch_script
      WINDOWS ? write_batch_script : write_shell_script
    end

    def write_shell_script
      script_path = @path / "#{script_basename}.sh"

      lines = [
        "#!/bin/sh",
        'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"',
      ]

      @env.each do |name, value|
        lines << "export #{name}=#{shell_word(value)}"
      end

      if @exec_args
        image, script, argv = @exec_args
        words = [root_path(image), root_path(script), *argv].map { |a| shell_word(a) }
        lines << "exec #{words.join(" ")} \"$@\""
      end

      File.write(script_path, lines.join("\n") + "\n")
      File.chmod(0755, script_path)
    end

    def write_batch_script
      script_path = @path / "#{script_basename}.bat"

      lines = [
        "@echo off",
        'set "SCRIPT_DIR=%~dp0"',
      ]

      @env.each do |name, value|
        lines << "set \"#{name}=#{batch_value(value).tr("/", "\\")}\""
      end

      if @exec_args
        image, script, argv = @exec_args
        words = [root_path(image), root_path(script)].map { |p| batch_value(p).tr("/", "\\") }
        words += argv.map { |a| batch_value(a) }
        lines << "#{words.map { |w| quote_and_escape(w) }.join(" ")} %*"
      end

      File.write(script_path, lines.join("\r\n") + "\r\n")
    end
  end
end
