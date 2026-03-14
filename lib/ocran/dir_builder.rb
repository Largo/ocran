# frozen_string_literal: true
require "pathname"
require "fileutils"
require_relative "build_constants"

module Ocran
  # Builder that outputs all files to a plain directory instead of a self-extracting
  # executable.  A launch script (`.sh` on POSIX, `.bat` on Windows) is written at
  # the root of the directory so the packaged app can be started directly.
  class DirBuilder
    include BuildConstants

    WINDOWS = Gem.win_platform?

    attr_reader :data_size

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

    # Replace the EXTRACT_ROOT placeholder ("|") in a value string with
    # the runtime directory variable.
    def replace_root(value, root_var)
      value.gsub("#{EXTRACT_ROOT}/", "#{root_var}/")
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
        replaced = replace_root(value, "$SCRIPT_DIR")
        lines << "export #{name}=\"#{replaced}\""
      end

      if @exec_args
        image, script, argv = @exec_args
        image_r = replace_root(image, "$SCRIPT_DIR")
        script_r = replace_root(script, "$SCRIPT_DIR")

        # Prepend SCRIPT_DIR to relative paths
        image_r = "$SCRIPT_DIR/#{image_r}" unless image_r.start_with?("/", "$SCRIPT_DIR")
        script_r = "$SCRIPT_DIR/#{script_r}" unless script_r.start_with?("/", "$SCRIPT_DIR")

        args = argv.map { |a| "\"#{replace_root(a, "$SCRIPT_DIR")}\"" }.join(" ")
        exec_line = "exec \"#{image_r}\" \"#{script_r}\""
        exec_line += " #{args}" unless args.empty?
        exec_line += ' "$@"'
        lines << exec_line
      end

      File.write(script_path, lines.join("\n") + "\n")
      File.chmod(0755, script_path)
    end

    def write_batch_script
      script_path = @path / "#{script_basename}.bat"

      lines = [
        "@echo off",
        "set SCRIPT_DIR=%~dp0",
      ]

      @env.each do |name, value|
        replaced = replace_root(value, "%SCRIPT_DIR%").tr("/", "\\")
        lines << "set #{name}=#{replaced}"
      end

      if @exec_args
        image, script, argv = @exec_args
        image_r = replace_root(image, "%SCRIPT_DIR%").tr("/", "\\")
        script_r = replace_root(script, "%SCRIPT_DIR%").tr("/", "\\")

        image_r = "%SCRIPT_DIR%#{image_r}" unless image_r.include?("%SCRIPT_DIR%") || File.absolute_path?(image_r)
        script_r = "%SCRIPT_DIR%#{script_r}" unless script_r.include?("%SCRIPT_DIR%") || File.absolute_path?(script_r)

        args = argv.map { |a| replace_root(a, "%SCRIPT_DIR%") }.join(" ")
        exec_line = "\"#{image_r}\" \"#{script_r}\""
        exec_line += " #{args}" unless args.empty?
        exec_line += " %*"
        lines << exec_line
      end

      File.write(script_path, lines.join("\r\n") + "\r\n")
    end
  end
end
