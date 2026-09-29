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

    # +script_name+ names the launch script (without extension); it defaults
    # to the name of the script that is executed. Direction passes the
    # user's script, because what is executed can be a generated launcher
    # (see Direction#generate_rubyopt_launcher).
    #
    # +chdir_before+ and +chdir_exe_dir+ mirror the stub flags of the same
    # names (--chdir-first, --chdir-exe-dir): the launch script changes into
    # the directory of the packed script, or into its own directory, which
    # is where the output directory keeps the application.
    def initialize(path, script_name: nil, chdir_before: false, chdir_exe_dir: false)
      @path = Pathname(path)
      @script_name = script_name
      @chdir_before = chdir_before
      @chdir_exe_dir = chdir_exe_dir
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

    # PowerShell command for create_zip on Windows. The paths come in through
    # the environment rather than being spliced into the command, so no
    # character in them (a quote in a user name, brackets) can change its
    # meaning; -LiteralPath keeps wildcards in the source path literal.
    POWERSHELL_ZIP_COMMAND =
      "$ErrorActionPreference = 'Stop'; " \
      "Get-ChildItem -LiteralPath $env:OCRAN_ZIP_SOURCE -Force | " \
      "Compress-Archive -DestinationPath $env:OCRAN_ZIP_DESTINATION"

    # Create a zip archive from a source directory, replacing any archive
    # already at +zip_path+.
    # Uses the `zip` command on POSIX and PowerShell on Windows.
    def self.create_zip(zip_path, source_dir)
      zip_path = File.expand_path(zip_path.to_s)
      # Both tools add to an existing archive rather than replace it (zip
      # keeps entries the new tree no longer has; Compress-Archive refuses
      # without -Force), so start from nothing.
      FileUtils.rm_f(zip_path)
      if Gem.win_platform?
        env = { "OCRAN_ZIP_SOURCE" => source_dir.to_s, "OCRAN_ZIP_DESTINATION" => zip_path }
        system(env, "powershell", "-NoProfile", "-NonInteractive", "-Command", POWERSHELL_ZIP_COMMAND,
               exception: true)
      else
        # -y stores symlinks (the libruby.so aliases) as links; without it
        # zip follows them and stores the library once per alias.
        Dir.chdir(source_dir) do
          system("zip", "-q", "-r", "-y", zip_path, ".", exception: true)
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

    # The batch script's reference to its own directory, which ends in a
    # backslash; see WindowsCommandEscaping#batch_value.
    BATCH_SCRIPT_DIR = "%SCRIPT_DIR%"

    # The directory the launch script changes into before it starts the
    # application, as a packed path (see root_path), or nil to stay put.
    def chdir_target
      if @chdir_exe_dir
        EXTRACT_ROOT.to_s
      elsif @chdir_before && @exec_args
        dir = File.dirname(@exec_args[1])
        dir == "." ? EXTRACT_ROOT.to_s : root_path(dir)
      end
    end

    def script_basename
      return @script_name.to_s if @script_name

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

      if (dir = chdir_target)
        target = dir == EXTRACT_ROOT.to_s ? '"$SCRIPT_DIR"' : shell_word(dir)
        lines << "cd #{target} || exit 1"
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

      # setlocal keeps the variables and the working directory set here from
      # outliving the script in the cmd.exe session that ran it.
      lines = [
        "@echo off",
        "setlocal",
        'set "SCRIPT_DIR=%~dp0"',
      ]

      @env.each do |name, value|
        lines << "set \"#{name}=#{batch_value(value, BATCH_SCRIPT_DIR).tr("/", "\\")}\""
      end

      if (dir = chdir_target)
        target = dir == EXTRACT_ROOT.to_s ? BATCH_SCRIPT_DIR : batch_value(dir, BATCH_SCRIPT_DIR).tr("/", "\\")
        lines << "cd /d #{quote_and_escape(target)} || exit /b 1"
      end

      if @exec_args
        image, script, argv = @exec_args
        words = [root_path(image), root_path(script)].map { |p| batch_value(p, BATCH_SCRIPT_DIR).tr("/", "\\") }
        words += argv.map { |a| batch_value(a, BATCH_SCRIPT_DIR) }
        lines << "#{words.map { |w| quote_and_escape(w) }.join(" ")} %*"
      end

      File.write(script_path, lines.join("\r\n") + "\r\n")
    end
  end
end
